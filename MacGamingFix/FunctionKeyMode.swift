import IOKit

class FunctionKeyMode {
    private var connection: io_connect_t = 0
    private var originalMode: UInt32?

    private typealias IOHIDGetParameterFn = @convention(c) (
        io_connect_t, CFString, IOByteCount,
        UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<IOByteCount>
    ) -> kern_return_t

    private typealias IOHIDSetParameterFn = @convention(c) (
        io_connect_t, CFString, UnsafeMutablePointer<UInt32>, UInt32
    ) -> kern_return_t

    private let getParam: IOHIDGetParameterFn?
    private let setParam: IOHIDSetParameterFn?

    init() {
        let handle = dlopen(nil, RTLD_LAZY)
        if let sym = dlsym(handle, "IOHIDGetParameter") {
            getParam = unsafeBitCast(sym, to: IOHIDGetParameterFn.self)
        } else {
            getParam = nil
        }
        if let sym = dlsym(handle, "IOHIDSetParameter") {
            setParam = unsafeBitCast(sym, to: IOHIDSetParameterFn.self)
        } else {
            setParam = nil
        }
    }

    func activate() {
        guard let getParam, let setParam else { return }
        guard ensureConnection() else { return }

        // Capture the original mode so we can restore it later.
        var current: UInt32 = 0
        var size = IOByteCount(MemoryLayout<UInt32>.size)
        let readResult = getParam(
            connection,
            "HIDFKeyMode" as CFString,
            IOByteCount(MemoryLayout<UInt32>.size),
            &current,
            &size
        )
        if readResult == KERN_SUCCESS {
            originalMode = current
        }

        // Set to standard function keys (mode 1).
        var mode: UInt32 = 1
        _ = setParam(connection, "HIDFKeyMode" as CFString, &mode, UInt32(MemoryLayout<UInt32>.size))
    }

    func deactivate() {
        guard let setParam else { return }
        guard ensureConnection() else { return }
        guard let originalMode else { return }

        var mode = originalMode
        _ = setParam(connection, "HIDFKeyMode" as CFString, &mode, UInt32(MemoryLayout<UInt32>.size))
        self.originalMode = nil
    }

    deinit {
        deactivate()
        closeConnection()
    }

    // MARK: - Connection

    private func ensureConnection() -> Bool {
        if connection != 0 { return true }

        guard let matching = IOServiceMatching("IOHIDSystem") else { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        let status = IOServiceOpen(service, mach_task_self_, 1, &conn)
        guard status == KERN_SUCCESS else { return false }

        connection = conn
        return true
    }

    private func closeConnection() {
        guard connection != 0 else { return }
        IOServiceClose(connection)
        connection = 0
    }
}
