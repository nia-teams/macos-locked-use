import ApplicationServices
import Foundation
import IOKit.hid
import os

/// Supplement the filtering CG tap with hardware activity detection. No HID
/// values, key usages, text, device names or serial numbers are read or logged.
/// Secure Event Input delivery must be validated on the target OS before the
/// Broker's production validation stamp may be written.
@MainActor
final class PhysicalInputMonitor {
    private nonisolated let worker = OSAllocatedUnfairLock<Worker?>(initialState: nil)
    private let activity: @MainActor () -> Void
    private let failure: @MainActor () -> Void

    nonisolated var inputState: (activityDetected: Bool, healthy: Bool) {
        worker.withLock { $0?.inputState ?? (false, false) }
    }
    nonisolated var activityDetected: Bool { inputState.activityDetected }
    nonisolated var healthy: Bool { inputState.healthy }

    init(activity: @escaping @MainActor () -> Void, failure: @escaping @MainActor () -> Void) {
        self.activity = activity; self.failure = failure
    }

    func start() throws {
        guard worker.withLock({ $0 == nil }) else { return }
        guard CGPreflightListenEventAccess() else { throw GuardianError.message("Input Monitoring missing") }
        let active = Worker(observer: self)
        worker.withLock { $0 = active }
        guard active.start() else {
            stop()
            throw GuardianError.message("Hardware input activity monitor unavailable")
        }
    }

    func stop() {
        let active = worker.withLock { slot -> Worker? in
            defer { slot = nil }
            return slot
        }
        active?.stop()
    }

    // IOKit handles belong exclusively to the worker thread. The lock protects
    // the run-loop reference and latch shared with the main-actor event taps.
    private final class Worker: @unchecked Sendable {
        // Assigned only at initialization; Swift owns zeroing the weak reference.
        private weak var observer: PhysicalInputMonitor?
        private let stateLock = NSLock()
        private var runLoop: CFRunLoop?
        private var state = (activityDetected: false, healthy: false, faulted: false)
        private let ready = DispatchSemaphore(value: 0)
        private let finished = DispatchGroup()
        private var manager: IOHIDManager?
        private var directlyOpenedDevices: [IOHIDDevice] = []

        init(observer: PhysicalInputMonitor) { self.observer = observer }

        var inputState: (activityDetected: Bool, healthy: Bool) {
            stateLock.withLock { (state.activityDetected, state.healthy) }
        }

        func start() -> Bool {
            finished.enter()
            let thread = Thread { [self] in
                defer { finished.leave() }
                autoreleasepool { run() }
            }
            thread.name = "LockedUse Physical Input"
            thread.qualityOfService = .userInteractive
            thread.start()
            ready.wait()
            return inputState.healthy
        }

        func stop() {
            if let loop = stateLock.withLock({ runLoop }) {
                // Queue the stop even if the worker has signalled readiness but
                // not yet entered CFRunLoopRun. Never wait on the main actor there.
                CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
                    CFRunLoopStop(CFRunLoopGetCurrent())
                }
                CFRunLoopWakeUp(loop)
            }
            finished.wait()
        }

        private func run() {
            let loop: CFRunLoop = CFRunLoopGetCurrent()
            var context = CFRunLoopSourceContext()
            context.perform = { _ in }
            guard let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context) else {
                ready.signal()
                return
            }
            CFRunLoopAddSource(loop, keepAlive, .defaultMode)
            defer {
                close(on: loop)
                CFRunLoopRemoveSource(loop, keepAlive, .defaultMode)
                CFRunLoopSourceInvalidate(keepAlive)
                stateLock.withLock {
                    state.healthy = false
                    runLoop = nil
                }
            }
            guard open(on: loop) else {
                ready.signal()
                return
            }
            let healthy = stateLock.withLock {
                // A callback during open makes startup fail closed, even if
                // the IOKit calls themselves report success.
                state.healthy = !state.faulted
                runLoop = state.healthy ? loop : nil
                return state.healthy
            }
            ready.signal()
            if healthy { CFRunLoopRun() }
        }

        private func open(on loop: CFRunLoop) -> Bool {
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = manager
            let matches: [[String: Int]] = [
                [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
                [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
                [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
                [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer, kIOHIDDeviceUsageKey: kHIDUsage_Csmr_ConsumerControl],
            ]
            IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterInputValueCallback(manager, Self.inputCallback, context)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { pointer, _, _, _ in
                guard let pointer else { return }
                Unmanaged<Worker>.fromOpaque(pointer).takeUnretainedValue().recordFailure()
            }, context)
            IOHIDManagerScheduleWithRunLoop(manager, loop, CFRunLoopMode.defaultMode.rawValue)
            let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            guard let devices = IOHIDManagerCopyDevices(manager), CFSetGetCount(devices) > 0 else { return false }
            if openResult != kIOReturnSuccess {
                // An exclusive grab (e.g. Karabiner-Elements) can prevent the
                // manager open. Keep monitoring devices that can be opened,
                // including a virtual device re-emitting keys from the grabber.
                guard openResult == kIOReturnExclusiveAccess,
                      openDevicesIndividually(devices, context: context, on: loop) > 0 else { return false }
            }
            return true
        }

        private static let inputCallback: IOHIDValueCallback = { pointer, result, _, _ in
            guard let pointer else { return }
            let worker = Unmanaged<Worker>.fromOpaque(pointer).takeUnretainedValue()
            if result != kIOReturnSuccess { worker.recordFailure() }
            else { worker.recordActivity() }
        }

        private func recordActivity() {
            guard stateLock.withLock({
                guard !state.activityDetected else { return false }
                state.activityDetected = true
                return true
            }) else { return }
            notify(failed: false)
        }

        private func recordFailure() {
            guard stateLock.withLock({
                let wasHealthy = state.healthy
                state.faulted = true
                state.healthy = false
                return wasHealthy
            }) else { return }
            notify(failed: true)
        }

        private func notify(failed: Bool) {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let observer = self.observer,
                          observer.worker.withLock({ $0 === self }) else { return }
                    if failed { observer.failure() }
                    else { observer.activity() }
                }
            }
        }

        private func openDevicesIndividually(_ devices: CFSet, context: UnsafeMutableRawPointer, on loop: CFRunLoop) -> Int {
            var pointers = [UnsafeRawPointer?](repeating: nil, count: CFSetGetCount(devices))
            CFSetGetValues(devices, &pointers)
            for case let pointer? in pointers {
                let device = Unmanaged<IOHIDDevice>.fromOpaque(pointer).takeUnretainedValue()
                guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
                IOHIDDeviceRegisterInputValueCallback(device, Self.inputCallback, context)
                IOHIDDeviceScheduleWithRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
                directlyOpenedDevices.append(device)
            }
            return directlyOpenedDevices.count
        }

        private func close(on loop: CFRunLoop) {
            for device in directlyOpenedDevices {
                IOHIDDeviceUnscheduleFromRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
                _ = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            directlyOpenedDevices = []
            if let manager {
                IOHIDManagerUnscheduleFromRunLoop(manager, loop, CFRunLoopMode.defaultMode.rawValue)
                _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            manager = nil
        }
    }
}
