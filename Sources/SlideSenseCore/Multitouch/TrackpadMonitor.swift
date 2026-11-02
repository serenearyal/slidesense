import CoreFoundation
import CoreGraphics
import Darwin
import Foundation

// MARK: - Private framework layout

/// Memory layout of the private `MultitouchSupport.framework` touch record.
///
/// 96 bytes on 64-bit; verified against OpenMultitouchSupport and FingerMgmt.
struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalized: MTVector
    var size: Float
    var unknown3: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTVector
    var unknown5a: Int32
    var unknown5b: Int32
    var density: Float
}

struct MTPoint {
    var x: Float
    var y: Float
}

struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

typealias MTDeviceRef = UnsafeMutableRawPointer

typealias MTFrameCallback = @convention(c) (
    MTDeviceRef?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Int32

/// Thin dlopen wrapper. Using `dlsym` keeps us independent of link flags and
/// lets the app degrade gracefully on hardware without a trackpad.
final class MultitouchLibrary {
    static let shared: MultitouchLibrary? = MultitouchLibrary()

    typealias CreateDefaultFn = @convention(c) () -> MTDeviceRef?
    typealias CreateListFn = @convention(c) () -> CFArray?
    typealias RegisterFn = @convention(c) (MTDeviceRef, MTFrameCallback) -> Void
    typealias UnregisterFn = @convention(c) (MTDeviceRef, MTFrameCallback) -> Void
    typealias StartFn = @convention(c) (MTDeviceRef, Int32) -> Void
    typealias StopFn = @convention(c) (MTDeviceRef) -> Void
    typealias BuiltInFn = @convention(c) (MTDeviceRef) -> Bool
    typealias IsRunningFn = @convention(c) (MTDeviceRef) -> Bool

    let createDefault: CreateDefaultFn?
    let createList: CreateListFn?
    let register: RegisterFn
    let unregister: UnregisterFn?
    let start: StartFn
    let stop: StopFn?
    let isBuiltIn: BuiltInFn?
    let isRunning: IsRunningFn?

    private init(
        createDefault: CreateDefaultFn?,
        createList: CreateListFn?,
        register: @escaping RegisterFn,
        unregister: UnregisterFn?,
        start: @escaping StartFn,
        stop: StopFn?,
        isBuiltIn: BuiltInFn?,
        isRunning: IsRunningFn?
    ) {
        self.createDefault = createDefault
        self.createList = createList
        self.register = register
        self.unregister = unregister
        self.start = start
        self.stop = stop
        self.isBuiltIn = isBuiltIn
        self.isRunning = isRunning
    }

    convenience init?() {
        guard let handle = MultitouchLibrary.openFramework() else { return nil }

        guard
            let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
            let startSym = dlsym(handle, "MTDeviceStart")
        else {
            return nil
        }

        let register = unsafeBitCast(registerSym, to: RegisterFn.self)
        let start = unsafeBitCast(startSym, to: StartFn.self)
        let createDefault = dlsym(handle, "MTDeviceCreateDefault").map { unsafeBitCast($0, to: CreateDefaultFn.self) }
        let createList = dlsym(handle, "MTDeviceCreateList").map { unsafeBitCast($0, to: CreateListFn.self) }
        let unregister = dlsym(handle, "MTUnregisterContactFrameCallback").map { unsafeBitCast($0, to: UnregisterFn.self) }
        let stop = dlsym(handle, "MTDeviceStop").map { unsafeBitCast($0, to: StopFn.self) }
        let builtIn = dlsym(handle, "MTDeviceIsBuiltIn").map { unsafeBitCast($0, to: BuiltInFn.self) }
        let isRunning = dlsym(handle, "MTDeviceIsRunning").map { unsafeBitCast($0, to: IsRunningFn.self) }

        guard createDefault != nil || createList != nil else { return nil }

        self.init(
            createDefault: createDefault,
            createList: createList,
            register: register,
            unregister: unregister,
            start: start,
            stop: stop,
            isBuiltIn: builtIn,
            isRunning: isRunning
        )
    }

    private static func openFramework() -> UnsafeMutableRawPointer? {
        let candidates = [
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/A/MultitouchSupport",
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/Current/MultitouchSupport"
        ]
        for path in candidates {
            if let handle = dlopen(path, RTLD_NOW) {
                return handle
            }
        }
        return nil
    }
}

// MARK: - Callback routing

/// The private API has no user-data pointer, so one process-wide router
/// forwards frames to whichever monitor is currently active.
enum TouchRouter {
    private static let lock = NSLock()
    private static var current: ((UnsafeMutablePointer<MTTouch>?, Int, Double) -> Void)?

    static var handler: ((UnsafeMutablePointer<MTTouch>?, Int, Double) -> Void)? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// Every frame is forwarded, also the empty one that follows the last lift.
    static let callback: MTFrameCallback = { _, touches, count, timestamp, _ in
        guard let handler = TouchRouter.handler else { return 0 }
        handler(touches?.assumingMemoryBound(to: MTTouch.self), Int(max(count, 0)), timestamp)
        return 0
    }
}

// MARK: - Monitor

/// Streams raw finger positions off the built-in trackpad.
///
/// Coordinates arrive normalised to 0…1 with the origin at the bottom-left of
/// the pad: `x` grows to the right, `y` grows towards the screen.
public final class TrackpadMonitor {
    /// Set before calling `start()`. Delivered on the framework's touch thread.
    public var onFrame: ((TouchFrame) -> Void)?
    /// Every frame as the framework reports it, empty frames included (`--record-touches`).
    public var onRawFrame: ((RawTouchFrame) -> Void)?

    /// Flip the vertical axis for trackpads that report it the other way up.
    public var flipVertical = false

    public static var isAvailable: Bool { MultitouchLibrary.shared != nil }

    private var devices: [MTDeviceRef] = []
    private var retainedList: CFArray?
    private var running = false
    private let stateLock = NSLock()

    public init() {}

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    @discardableResult
    public func start() -> Bool {
        guard let library = MultitouchLibrary.shared else { return false }
        stop()
        TouchRouter.handler = { [weak self] records, count, timestamp in
            self?.handle(records: records, count: count, timestamp: timestamp)
        }

        let found = enumerateDevices(library: library)
        guard !found.isEmpty else {
            TouchRouter.handler = nil
            return false
        }

        for device in found {
            library.register(device, TouchRouter.callback)
            library.start(device, 0)
        }

        stateLock.lock()
        devices = found
        running = true
        stateLock.unlock()
        return true
    }

    public func stop() {
        stateLock.lock()
        let current = devices
        let wasRunning = running
        devices = []
        running = false
        stateLock.unlock()

        guard wasRunning || !current.isEmpty else {
            TouchRouter.handler = nil
            return
        }
        if let library = MultitouchLibrary.shared {
            for device in current {
                library.unregister?(device, TouchRouter.callback)
                library.stop?(device)
            }
        }
        retainedList = nil
        TouchRouter.handler = nil
    }

    public func restart() {
        stop()
        start()
    }

    // MARK: Private

    private func enumerateDevices(library: MultitouchLibrary) -> [MTDeviceRef] {
        var result: [MTDeviceRef] = []

        if let createList = library.createList, let list = createList() {
            retainedList = list
            let count = CFArrayGetCount(list)
            for index in 0..<count {
                guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
                let device = UnsafeMutableRawPointer(mutating: raw)
                if let isBuiltIn = library.isBuiltIn, isBuiltIn(device) == false { continue }
                result.append(device)
            }
            if !result.isEmpty { return result }
        }

        if let createDefault = library.createDefault, let device = createDefault() {
            result.append(device)
        }
        return result
    }

    private func handle(records: UnsafeMutablePointer<MTTouch>?, count: Int, timestamp: Double) {
        var raw: [RawTouch] = []
        if let records {
            raw.reserveCapacity(count)
            for index in 0..<count {
                let record = records[index]
                raw.append(RawTouch(
                    id: record.identifier,
                    state: record.state,
                    x: Double(record.normalized.position.x),
                    y: Double(record.normalized.position.y),
                    size: Double(record.size)
                ))
            }
        }
        let frame = RawTouchFrame(t: timestamp, contacts: raw)
        onRawFrame?(frame)
        // Empty frames are delivered too: the one after the last lift ends a gesture.
        onFrame?(TouchFrame(raw: frame, flipVertical: flipVertical))
    }
}

/// Debug helper used by `--dump-touches`.
public enum TrackpadDiagnostics {
    public static func dump(seconds: Double = 30) {
        guard TrackpadMonitor.isAvailable else {
            print("MultitouchSupport.framework is not available on this machine.")
            return
        }
        let monitor = TrackpadMonitor()
        monitor.onFrame = { frame in
            let summary = frame.contacts.map {
                String(format: "id=%d x=%.3f y=%.3f %@", $0.id, $0.x, $0.y, $0.isTouching ? "touch" : "off")
            }.joined(separator: " | ")
            print(String(format: "t=%.3f %@", frame.timestamp, summary))
        }
        guard monitor.start() else {
            print("No multitouch device found.")
            return
        }
        print("Listening for \(Int(seconds))s — touch the trackpad…")
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        monitor.stop()
    }

    /// Writes every raw frame to `path` as JSON lines, for bug reports and test fixtures.
    public static func record(to path: String, seconds: Double) {
        guard TrackpadMonitor.isAvailable else {
            print("MultitouchSupport.framework is not available on this machine.")
            return
        }
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let file = FileHandle(forWritingAtPath: path) else {
            print("Cannot write \(path)")
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var frames = 0
        let monitor = TrackpadMonitor()
        monitor.onRawFrame = { frame in
            var frame = frame
            frame.button = CGEventSource.buttonState(.combinedSessionState, button: .left)
            guard let line = try? encoder.encode(frame) else { return }
            file.write(line + Data("\n".utf8))
            frames += 1
        }
        guard monitor.start() else {
            print("No multitouch device found.")
            return
        }
        print("Recording for \(Int(seconds))s to \(path). Do the gestures now…")
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        monitor.stop()
        try? file.close()
        print("Done: \(frames) frames.")
    }
}
