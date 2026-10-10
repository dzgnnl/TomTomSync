import Foundation
import IOKit
import IOKit.hid

public enum TransportError: Error, CustomStringConvertible {
    case noDevice
    case openFailed(IOReturn)
    case sendFailed(IOReturn)
    case timeout
    case disconnected

    public var description: String {
        switch self {
        case .noDevice: return "No TomTom watch found. Is it connected via USB?"
        case .openFailed(let r): return "Could not open watch (IOReturn \(String(format: "0x%08x", r)))"
        case .sendFailed(let r): return "USB send failed (IOReturn \(String(format: "0x%08x", r)))"
        case .timeout: return "Timeout waiting for the watch to respond"
        case .disconnected: return "Watch disconnected"
        }
    }
}

/// Known TomTom watch USB product IDs (vendor 0x1390).
public enum WatchModel: Int, Sendable {
    case multisport = 0x7474   // Runner / Multi-Sport (1st gen)
    case sparkMusic = 0x7475   // Spark Music / Runner 2/3 Music / Adventurer
    case sparkCardio = 0x7477  // Spark Cardio / Runner 2/3 Cardio

    public static let vendorID = 0x1390

    public var name: String {
        switch self {
        case .multisport: return "Runner / Multi-Sport"
        case .sparkMusic: return "Spark Music / Runner Music / Adventurer"
        case .sparkCardio: return "Spark Cardio / Runner Cardio"
        }
    }

    /// Max payload per file-read and file-write message (from the Java implementation).
    var readChunk: Int { self == .multisport ? 50 : 242 }
    var writeChunk: Int { self == .multisport ? 54 : 246 }
    var packetSize: Int { self == .multisport ? 64 : 256 }
}

/// Talks to the watch through the IOKit HID API.
///
/// The watch is a vendor-defined HID device. Using IOHIDDevice (instead of
/// libusb) means macOS keeps its own HID driver attached, so no root and no
/// kernel-driver detaching is needed.
public final class HIDTransport: @unchecked Sendable {
    public let model: WatchModel
    public let serialNumber: String?

    private let device: IOHIDDevice
    private let lock = NSCondition()
    private var inbox: [[UInt8]] = []
    private var isRemoved = false
    private var inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputBufferSize: Int
    private let outputReportSize: Int
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    public static func findWatch() -> (IOHIDDevice, WatchModel)? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: WatchModel.vendorID] as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        for dev in set {
            let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? 0
            if let model = WatchModel(rawValue: pid) { return (dev, model) }
        }
        return nil
    }

    public init() throws {
        guard let (dev, model) = HIDTransport.findWatch() else { throw TransportError.noDevice }
        self.device = dev
        self.model = model
        self.serialNumber = IOHIDDeviceGetProperty(dev, kIOHIDSerialNumberKey as CFString) as? String

        let maxIn = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        let maxOut = IOHIDDeviceGetProperty(dev, kIOHIDMaxOutputReportSizeKey as CFString) as? Int ?? 0
        self.inputBufferSize = max(maxIn, model.packetSize)
        self.outputReportSize = maxOut > 0 ? maxOut : model.packetSize
        self.inputBuffer = .allocate(capacity: inputBufferSize)

        let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            inputBuffer.deallocate()
            throw TransportError.openFailed(r)
        }
        startRunLoop()
    }

    deinit {
        close()
        inputBuffer.deallocate()
    }

    public func close() {
        guard let rl = runLoop else { return }
        IOHIDDeviceUnscheduleFromRunLoop(device, rl, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        CFRunLoopStop(rl)
        runLoop = nil
    }

    /// Input reports and removal notifications are delivered on a private
    /// thread's run loop so the request/response API can stay synchronous.
    private func startRunLoop() {
        let ready = DispatchSemaphore(value: 0)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let t = Thread { [device, inputBuffer, inputBufferSize] in
            let rl = CFRunLoopGetCurrent()!
            self.runLoop = rl
            IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, inputBufferSize, { ctx, result, _, _, _, report, length in
                guard let ctx else { return }
                let me = Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue()
                me.received(Array(UnsafeBufferPointer(start: report, count: length)))
            }, ctx)
            IOHIDDeviceRegisterRemovalCallback(device, { ctx, _, _ in
                guard let ctx else { return }
                Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue().removed()
            }, ctx)
            IOHIDDeviceScheduleWithRunLoop(device, rl, CFRunLoopMode.defaultMode.rawValue)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "TomTomKit.HID"
        t.start()
        thread = t
        ready.wait()
    }

    private func received(_ report: [UInt8]) {
        lock.lock(); inbox.append(report); lock.signal(); lock.unlock()
    }

    private func removed() {
        lock.lock(); isRemoved = true; lock.broadcast(); lock.unlock()
    }

    /// Sends one packet. `packet[0]` is the report ID (0x09 for requests).
    public func send(_ packet: [UInt8]) throws {
        lock.lock(); let gone = isRemoved; inbox.removeAll(); lock.unlock()
        if gone { throw TransportError.disconnected }
        var buf = packet
        if buf.count < outputReportSize { buf += [UInt8](repeating: 0, count: outputReportSize - buf.count) }
        let r = buf.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(packet[0]), $0.baseAddress!, $0.count)
        }
        guard r == kIOReturnSuccess else { throw TransportError.sendFailed(r) }
    }

    /// Waits for the next input report.
    public func receive(timeout: TimeInterval = 5) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        while inbox.isEmpty {
            if isRemoved { throw TransportError.disconnected }
            if !lock.wait(until: deadline) { throw TransportError.timeout }
        }
        return inbox.removeFirst()
    }
}
