import Foundation
import IOKit
import IOKit.hid

public enum TransportError: Error, CustomStringConvertible {
    case noDevice
    case unsupportedDevice(Int)
    case busy
    case openFailed(IOReturn)
    case sendFailed(IOReturn)
    case timeout
    case disconnected
    case invalidReportSize(Int)

    public var description: String {
        switch self {
        case .noDevice: return "No TomTom watch found. Is it connected via USB?"
        case .unsupportedDevice(let id):
            return String(format: "This TomTom device is not supported (USB product ID 0x%04X)", id)
        case .busy: return "The watch is in use by TomTomSync or ttsync. Try again when that sync has finished."
        case .openFailed(let r): return "Could not open watch (IOReturn \(String(format: "0x%08x", r)))"
        case .sendFailed(let r): return "USB send failed (IOReturn \(String(format: "0x%08x", r)))"
        case .timeout: return "Timeout waiting for the watch to respond"
        case .disconnected: return "Watch disconnected"
        case .invalidReportSize(let size): return "Watch reports an unsupported HID report size (\(size) bytes)"
        }
    }
}

/// Known TomTom watch USB product IDs (vendor 0x1390).
public enum WatchModel: Int, Sendable {
    case multisport = 0x7474   // Runner / Multi-Sport (1st gen)
    case sparkMusic = 0x7475   // Spark Music / Runner 2/3 Music / Adventurer
    case sparkCardioMusic = 0x7476  // Runner 3 / Spark 3 Cardio + Music (one report, untested)
    case sparkCardio = 0x7477  // Spark Cardio / Runner 2/3 Cardio

    public static let vendorID = 0x1390

    public var name: String {
        switch self {
        case .multisport: return "Runner / Multi-Sport"
        case .sparkMusic: return "Spark Music / Runner Music / Adventurer"
        case .sparkCardioMusic: return "Spark Cardio + Music / Runner Cardio + Music"
        case .sparkCardio: return "Spark Cardio / Runner Cardio"
        }
    }

    /// Max payload per file-read and file-write message (from the Java implementation).
    var readChunk: Int { self == .multisport ? 50 : 242 }
    var writeChunk: Int { self == .multisport ? 54 : 246 }
    var packetSize: Int { self == .multisport ? 64 : 256 }
}

/// The TomTom USB devices that are plugged in. TomTom's vendor ID is also on
/// devices that are not sports watches, and on watches this app doesn't know.
public struct PluggedDevices<Device: Hashable> {
    private var productIDs: [Device: Int] = [:]

    public init() {}

    public mutating func plugged(_ device: Device, productID: Int) { productIDs[device] = productID }
    public mutating func unplugged(_ device: Device) { productIDs[device] = nil }

    public var watchConnected: Bool { productIDs.values.contains { WatchModel(rawValue: $0) != nil } }
    /// The product ID of a device that is not a known watch, when no watch is connected.
    public var unsupportedProductID: Int? { watchConnected ? nil : productIDs.values.min() }
}

/// What `Watch` needs from a connection. `HIDTransport` is the real one; tests
/// use an in-memory watch.
public protocol WatchTransport: AnyObject {
    var model: WatchModel { get }
    var serialNumber: String? { get }
    /// Sends one packet. `packet[0]` is the report ID (0x09 for requests).
    func send(_ packet: [UInt8]) throws
    /// Waits for the next input report.
    func receive(timeout: TimeInterval) throws -> [UInt8]
    func close()
}

/// Lets one process at a time talk to the watch. macOS allows several to open
/// the device, but replies are matched to requests by a one-byte counter, so
/// two talkers would read each other's answers.
final class WatchLock {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TomTomSync/watch.lock")

    private var fd: Int32

    /// Throws `TransportError.busy` when another connection holds the lock.
    init(url: URL = WatchLock.defaultURL) throws {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        // Where locking itself doesn't work (the file can't be created, or the
        // home folder is on a volume without flock), syncing goes on without
        // it: never being able to sync is worse than the rare collision.
        guard fd >= 0 else { return }
        var result: Int32
        repeat { result = flock(fd, LOCK_EX | LOCK_NB) } while result != 0 && errno == EINTR
        guard result != 0 else { return }
        let taken = errno == EWOULDBLOCK
        Darwin.close(fd)
        fd = -1
        if taken { throw TransportError.busy }
    }

    /// The lock also goes when the process exits or crashes.
    func release() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    deinit { release() }
}

/// Talks to the watch through the IOKit HID API.
///
/// The watch is a vendor-defined HID device. Using IOHIDDevice (instead of
/// libusb) means macOS keeps its own HID driver attached, so no root and no
/// kernel-driver detaching is needed.
public final class HIDTransport: WatchTransport, @unchecked Sendable {
    /// Known models use reports of 64 or 256 bytes. Keep room for descriptor
    /// variations while refusing attacker-controlled multi-gigabyte sizes.
    private static let maximumReportSize = 4096
    private static let maximumQueuedReports = 64

    public let model: WatchModel
    public let serialNumber: String?

    private let device: IOHIDDevice
    private let usbLock: WatchLock
    private let lock = NSCondition()
    private var inbox: [[UInt8]] = []
    private var isRemoved = false
    private var inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputBufferSize: Int
    private let outputReportSize: Int
    private var runLoop: CFRunLoop?

    /// TomTom USB devices that are plugged in, with their product IDs.
    private static func tomTomDevices() -> [(IOHIDDevice, Int)] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: WatchModel.vendorID] as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return set.map { ($0, IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? Int ?? 0) }
    }

    public static func findWatch() -> (IOHIDDevice, WatchModel)? {
        for (dev, pid) in tomTomDevices() {
            if let model = WatchModel(rawValue: pid) { return (dev, model) }
        }
        return nil
    }

    /// Why `findWatch()` found nothing: no TomTom device at all, or one that
    /// is not a watch this app knows.
    public static func noWatchError() -> TransportError {
        tomTomDevices().map(\.1).min().map(TransportError.unsupportedDevice) ?? .noDevice
    }

    public init() throws {
        guard let (dev, model) = HIDTransport.findWatch() else { throw Self.noWatchError() }
        self.usbLock = try WatchLock()
        self.device = dev
        self.model = model
        self.serialNumber = IOHIDDeviceGetProperty(dev, kIOHIDSerialNumberKey as CFString) as? String

        let maxIn = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        let maxOut = IOHIDDeviceGetProperty(dev, kIOHIDMaxOutputReportSizeKey as CFString) as? Int ?? 0
        guard maxIn <= Self.maximumReportSize, maxOut <= Self.maximumReportSize else {
            throw TransportError.invalidReportSize(max(maxIn, maxOut))
        }
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
        // Last, so the next process only gets in once this one has let go of the device.
        defer { usbLock.release() }
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
            IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, inputBufferSize, { ctx, _, _, _, _, report, length in
                guard let ctx else { return }
                let me = Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue()
                guard length > 0, length <= me.inputBufferSize else { return }
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
        ready.wait()
    }

    private func received(_ report: [UInt8]) {
        lock.lock()
        if inbox.count == Self.maximumQueuedReports { inbox.removeFirst() }
        inbox.append(report)
        lock.signal()
        lock.unlock()
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
