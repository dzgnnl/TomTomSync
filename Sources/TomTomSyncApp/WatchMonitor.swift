import Foundation
import IOKit.hid
import TomTomKit

/// Notifies when a TomTom watch is plugged in or removed.
final class WatchMonitor {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var devices = PluggedDevices<IOHIDDevice>()
    /// Whether a supported watch is connected and, if not, the USB product ID
    /// of a TomTom device that isn't one.
    private let onChange: (Bool, Int?) -> Void

    init(onChange: @escaping (Bool, Int?) -> Void) {
        self.onChange = onChange
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: WatchModel.vendorID] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            let me = Unmanaged<WatchMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            me.devices.plugged(device, productID: IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0)
            me.report()
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            let me = Unmanaged<WatchMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            me.devices.unplugged(device)
            me.report()
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // Matching only; the sync opens the device itself.
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func report() { onChange(devices.watchConnected, devices.unsupportedProductID) }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
