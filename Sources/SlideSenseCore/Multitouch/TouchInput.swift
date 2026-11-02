import CoreGraphics
import Foundation

/// One finger reported by the trackpad.
public struct TouchContact: Sendable, Equatable {
    /// Stable for the lifetime of a touch.
    public var id: Int32
    /// 0 = left, 1 = right.
    public var x: Double
    /// 0 = closest to you, 1 = closest to the screen.
    public var y: Double
    public var isTouching: Bool

    public init(id: Int32, x: Double, y: Double, isTouching: Bool) {
        self.id = id
        self.x = x
        self.y = y
        self.isTouching = isTouching
    }
}

/// One contact exactly as `MultitouchSupport` reports it, before any mapping.
/// Recorded by `--record-touches` and replayed by the tests.
public struct RawTouch: Codable, Sendable, Equatable {
    public var id: Int32
    /// 1-2 = hovering, 3 = make touch, 4 = touching, 5-7 = lifting.
    public var state: Int32
    public var x: Double
    public var y: Double
    public var size: Double

    public init(id: Int32, state: Int32, x: Double, y: Double, size: Double) {
        self.id = id
        self.state = state
        self.x = x
        self.y = y
        self.size = size
    }

    /// The two states that mean "a finger is on the glass" (make touch, touching).
    public var isTouching: Bool { state == 3 || state == 4 }
}

/// One device frame, including the empty frame sent after the last finger lifts.
public struct RawTouchFrame: Codable, Sendable {
    public var t: TimeInterval
    public var contacts: [RawTouch]
    /// Whether the trackpad button was pressed (recordings only).
    public var button: Bool?

    public init(t: TimeInterval, contacts: [RawTouch], button: Bool? = nil) {
        self.t = t
        self.contacts = contacts
        self.button = button
    }
}

/// All contacts seen in one device frame.
public struct TouchFrame: Sendable {
    public var timestamp: TimeInterval
    public var contacts: [TouchContact]

    public init(timestamp: TimeInterval, contacts: [TouchContact]) {
        self.timestamp = timestamp
        self.contacts = contacts
    }

    public var activeContacts: [TouchContact] {
        contacts.filter(\.isTouching)
    }

    /// Maps a raw frame the way the app sees it. Shared by `TrackpadMonitor` and the
    /// replay tests, so recorded fixtures exercise the same path as the trackpad.
    public init(raw: RawTouchFrame, flipVertical: Bool = false) {
        self.init(timestamp: raw.t, contacts: raw.contacts.map {
            TouchContact(id: $0.id, x: $0.x, y: flipVertical ? 1 - $0.y : $0.y, isTouching: $0.isTouching)
        })
    }
}

/// Keyboard modifiers, read without touching the event stream.
public struct ModifierState: OptionSet, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let shift = ModifierState(rawValue: 1 << 0)
    public static let control = ModifierState(rawValue: 1 << 1)
    public static let option = ModifierState(rawValue: 1 << 2)
    public static let command = ModifierState(rawValue: 1 << 3)
    public static let fn = ModifierState(rawValue: 1 << 4)

    /// Reads the current session flags. Safe from any thread.
    public static var current: ModifierState {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        var state: ModifierState = []
        if flags.contains(.maskShift) { state.insert(.shift) }
        if flags.contains(.maskControl) { state.insert(.control) }
        if flags.contains(.maskAlternate) { state.insert(.option) }
        if flags.contains(.maskCommand) { state.insert(.command) }
        if flags.contains(.maskSecondaryFn) { state.insert(.fn) }
        return state
    }
}
