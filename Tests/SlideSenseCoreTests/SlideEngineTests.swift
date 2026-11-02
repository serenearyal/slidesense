import CoreGraphics
import XCTest
@testable import SlideSenseCore

private final class Recorder: SlideEngineDelegate {
    var begins: [EdgeAction] = []
    var updates: [(EdgeAction, Double)] = []
    var ends: [(EdgeAction, Double)] = []
    var ticks: [(EdgeAction, Double)] = []
    var commands: [MediaCommand] = []

    func slideEngine(_ engine: SlideEngine, didBeginSlide target: EdgeAction) {
        begins.append(target)
    }

    func slideEngine(_ engine: SlideEngine, didUpdateSlide target: EdgeAction, level: Double) {
        updates.append((target, level))
    }

    func slideEngine(_ engine: SlideEngine, didEndSlide target: EdgeAction, level: Double) {
        ends.append((target, level))
    }

    func slideEngine(_ engine: SlideEngine, didTick target: EdgeAction, level: Double) {
        ticks.append((target, level))
    }

    func slideEngine(_ engine: SlideEngine, didRecognize command: MediaCommand) {
        commands.append(command)
    }
}

final class SlideEngineTests: XCTestCase {
    private func makeEngine(_ configure: (inout EngineConfiguration) -> Void = { _ in }) -> (SlideEngine, Recorder) {
        let engine = SlideEngine()
        var config = EngineConfiguration()
        config.mediaStripEnabled = true
        configure(&config)
        engine.configuration = { config }
        engine.modifiers = { [] }
        engine.buttonDown = { false }
        let recorder = Recorder()
        engine.delegate = recorder
        return (engine, recorder)
    }

    private func frame(at time: TimeInterval, x: Double, y: Double, touching: Bool = true, id: Int32 = 1) -> TouchFrame {
        TouchFrame(timestamp: time, contacts: [TouchContact(id: id, x: x, y: y, isTouching: touching)])
    }

    /// A one-finger move in `steps` frames, 8 ms apart like the real trackpad. Returns the end time.
    @discardableResult
    private func move(
        _ engine: SlideEngine,
        id: Int32 = 1,
        from start: (x: Double, y: Double),
        to end: (x: Double, y: Double),
        at time: TimeInterval,
        steps: Int = 12
    ) -> TimeInterval {
        for step in 0...steps {
            let f = Double(step) / Double(steps)
            engine.process(frame(
                at: time + Double(step) * 0.008,
                x: start.x + (end.x - start.x) * f,
                y: start.y + (end.y - start.y) * f,
                id: id
            ))
        }
        return time + Double(steps) * 0.008
    }

    /// What a real lift sends (recorded on a MacBook Pro): the finger in the
    /// "lifting" states 5, 6, 6, 7, then one empty frame, then nothing.
    @discardableResult
    private func lift(_ engine: SlideEngine, id: Int32 = 1, x: Double, y: Double, at time: TimeInterval) -> TimeInterval {
        for (index, state) in [Int32(5), 6, 6, 7].enumerated() {
            let raw = RawTouchFrame(t: time + Double(index + 1) * 0.008, contacts: [
                RawTouch(id: id, state: state, x: x, y: y, size: 0.3)
            ])
            engine.process(TouchFrame(raw: raw))
        }
        engine.process(TouchFrame(timestamp: time + 0.04, contacts: []))
        return time + 0.04
    }

    /// Replays a recording made with `SlideSense --record-touches`, button state included.
    private func replay(_ name: String, into engine: SlideEngine) throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        var pressed = false
        engine.buttonDown = { pressed }
        for line in lines {
            let raw = try JSONDecoder().decode(RawTouchFrame.self, from: Data(line.utf8))
            pressed = raw.button ?? false
            engine.process(TouchFrame(raw: raw))
        }
    }

    func testRightSlideSenseChangesVolume() {
        var config = EngineConfiguration()
        config.currentVolume = 0.5
        let (engine, recorder) = makeEngine { $0 = config }

        engine.process(frame(at: 0.0, x: 0.95, y: 0.2))
        engine.process(frame(at: 0.02, x: 0.95, y: 0.4))
        engine.process(frame(at: 0.04, x: 0.95, y: 0.6))

        XCTAssertEqual(recorder.begins, [.volume])
        XCTAssertGreaterThan(recorder.updates.last?.1 ?? 0, 0.5)
        XCTAssertEqual(recorder.ends.count, 0) // still touching
    }

    func testLeftSlideSenseChangesBrightness() {
        var config = EngineConfiguration()
        config.currentBrightness = 0.5
        let (engine, recorder) = makeEngine { $0 = config }

        engine.process(frame(at: 0.0, x: 0.05, y: 0.8))
        engine.process(frame(at: 0.02, x: 0.05, y: 0.6))

        XCTAssertEqual(recorder.begins, [.brightness])
        XCTAssertEqual(recorder.updates.last?.1 ?? 1, 0.25, accuracy: 0.001)
    }

    func testMiddleTouchIsIgnored() {
        let (engine, recorder) = makeEngine()
        engine.process(frame(at: 0.0, x: 0.5, y: 0.5))
        engine.process(frame(at: 0.02, x: 0.55, y: 0.55))
        XCTAssertTrue(recorder.begins.isEmpty)
        XCTAssertTrue(recorder.updates.isEmpty)
    }

    func testSecondFingerCancelsSlide() {
        let (engine, recorder) = makeEngine()
        engine.process(frame(at: 0.0, x: 0.95, y: 0.2))
        engine.process(frame(at: 0.02, x: 0.95, y: 0.4))
        let twoFingers = TouchFrame(timestamp: 0.04, contacts: [
            TouchContact(id: 1, x: 0.95, y: 0.5, isTouching: true),
            TouchContact(id: 2, x: 0.5, y: 0.5, isTouching: true)
        ])
        engine.process(twoFingers)
        XCTAssertEqual(recorder.ends.count, 1)
    }

    func testLevelStopsAtBounds() {
        var config = EngineConfiguration()
        config.currentVolume = 0.9
        let (engine, recorder) = makeEngine { $0 = config }
        engine.process(frame(at: 0.0, x: 0.95, y: 0.2))
        engine.process(frame(at: 0.02, x: 0.95, y: 1.0))
        XCTAssertEqual(recorder.updates.last?.1 ?? 0, 1.0, accuracy: 0.001)
    }

    func testDoubleTapCornerMutes() {
        let (engine, recorder) = makeEngine()
        for index in 0..<2 {
            let base = Double(index) * 0.2
            engine.process(frame(at: base + 0.00, x: 0.95, y: 0.95))
            engine.process(frame(at: base + 0.05, x: 0.95, y: 0.95))
            engine.process(frame(at: base + 0.08, x: 0.95, y: 0.95, touching: false))
        }
        XCTAssertEqual(recorder.commands, [.mute])
    }

    func testSingleCornerTapDoesNotMute() {
        let (engine, recorder) = makeEngine()
        engine.process(frame(at: 0.0, x: 0.95, y: 0.95))
        engine.process(frame(at: 0.05, x: 0.95, y: 0.95))
        engine.process(frame(at: 0.08, x: 0.95, y: 0.95, touching: false))
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    func testBottomStripSwipeSendsNext() {
        let (engine, recorder) = makeEngine()
        engine.process(frame(at: 0.0, x: 0.8, y: 0.05))
        engine.process(frame(at: 0.02, x: 0.6, y: 0.05))
        engine.process(frame(at: 0.04, x: 0.4, y: 0.05))
        XCTAssertEqual(recorder.commands, [.next])
    }

    func testBottomStripReverseFlipsDirection() {
        let (engine, recorder) = makeEngine { $0.mediaStripReverse = true }
        engine.process(frame(at: 0.0, x: 0.2, y: 0.05))
        engine.process(frame(at: 0.04, x: 0.6, y: 0.05))
        XCTAssertEqual(recorder.commands, [.next])
    }

    // MARK: - Lifting ends a slide

    func testLiftEndsSlideAtOnce() {
        let (engine, recorder) = makeEngine()
        let end = move(engine, from: (0.95, 0.2), to: (0.95, 0.5), at: 0)
        XCTAssertEqual(recorder.begins, [.volume])

        // The first "lifting" frame already ends it; the app must not wait for more frames.
        engine.process(TouchFrame(raw: RawTouchFrame(t: end + 0.008, contacts: [
            RawTouch(id: 1, state: 5, x: 0.95, y: 0.5, size: 0.3)
        ])))
        XCTAssertEqual(recorder.ends.count, 1)
        XCTAssertFalse(engine.isTrackingSlide)
    }

    func testOtherEdgeRightAfterLiftChangesItsOwnLevel() {
        let (engine, recorder) = makeEngine()
        var time = move(engine, from: (0.95, 0.2), to: (0.95, 0.6), at: 0)
        time = lift(engine, x: 0.95, y: 0.6, at: time)
        let volumeUpdates = recorder.updates.count

        // A new finger on the left edge 30 ms later: brightness, never volume.
        move(engine, id: 2, from: (0.05, 0.2), to: (0.05, 0.6), at: time + 0.03)
        XCTAssertEqual(recorder.begins, [.volume, .brightness])
        XCTAssertTrue(recorder.updates.dropFirst(volumeUpdates).allSatisfy { $0.0 == .brightness })
        XCTAssertFalse(recorder.updates.dropFirst(volumeUpdates).isEmpty)
    }

    func testPointerMoveAfterSlideDoesNotContinueIt() {
        let (engine, recorder) = makeEngine()
        var time = move(engine, from: (0.95, 0.2), to: (0.95, 0.6), at: 0)
        time = lift(engine, x: 0.95, y: 0.6, at: time)
        let updates = recorder.updates.count

        // Two seconds later the user moves the pointer in the middle of the pad.
        move(engine, id: 2, from: (0.5, 0.5), to: (0.6, 0.3), at: time + 2)
        XCTAssertEqual(recorder.updates.count, updates)
        XCTAssertEqual(recorder.begins, [.volume])
        XCTAssertFalse(engine.isTrackingSlide)
    }

    func testNewFingerEndsOldSlideEvenWithoutLiftFrames() {
        let (engine, recorder) = makeEngine()
        let time = move(engine, from: (0.95, 0.2), to: (0.95, 0.6), at: 0)
        // No lift frames at all, a different finger appears on the left edge.
        move(engine, id: 2, from: (0.05, 0.2), to: (0.05, 0.6), at: time + 0.008)
        XCTAssertEqual(recorder.ends.first?.0, .volume)
        XCTAssertEqual(recorder.begins, [.volume, .brightness])
    }

    func testFrameAfterLongGapNeverContinuesSlide() {
        let (engine, recorder) = makeEngine()
        let time = move(engine, from: (0.95, 0.2), to: (0.95, 0.6), at: 0)
        // The lift was lost, and the same id shows up again much later in the middle.
        move(engine, from: (0.5, 0.5), to: (0.5, 0.2), at: time + 1)
        XCTAssertEqual(recorder.ends.count, 1)
        XCTAssertEqual(recorder.begins, [.volume])
    }

    func testLevelFollowsFingerBackToStart() {
        var config = EngineConfiguration()
        config.currentVolume = 0.5
        let (engine, recorder) = makeEngine { $0 = config }
        let time = move(engine, from: (0.95, 0.4), to: (0.95, 0.6), at: 0)
        move(engine, from: (0.95, 0.6), to: (0.95, 0.4), at: time + 0.008)
        XCTAssertEqual(recorder.updates.last?.1 ?? 0, 0.5, accuracy: 0.001)
    }

    // MARK: - Pointer moves are not slides

    func testSidewaysMoveFromEdgeIsPointer() {
        let (engine, recorder) = makeEngine()
        move(engine, from: (0.95, 0.5), to: (0.7, 0.52), at: 0)
        XCTAssertTrue(recorder.begins.isEmpty)
        XCTAssertTrue(recorder.updates.isEmpty)
    }

    func testDiagonalMoveFromEdgeIsPointer() {
        let (engine, recorder) = makeEngine()
        // 45 degrees on the real pad: 0.05 across is as long as 0.08 up.
        move(engine, from: (0.95, 0.3), to: (0.9, 0.38), at: 0)
        XCTAssertTrue(recorder.begins.isEmpty)
    }

    func testSlightlySlantedSlideStillCounts() {
        let (engine, recorder) = makeEngine()
        move(engine, from: (0.95, 0.2), to: (0.93, 0.6), at: 0)
        XCTAssertEqual(recorder.begins, [.volume])
    }

    func testSidewaysSettleThenSlideStillCounts() {
        let (engine, recorder) = makeEngine()
        // The finger centre drifts inwards as it flattens, then the finger slides up.
        let time = move(engine, from: (0.98, 0.36), to: (0.965, 0.36), at: 0)
        move(engine, from: (0.965, 0.36), to: (0.965, 0.45), at: time + 0.008)
        XCTAssertEqual(recorder.begins, [.volume])
    }

    func testMoveThatLeavesTheBandIsPointer() {
        let (engine, recorder) = makeEngine()
        // Goes inwards out of the band first, then up.
        let time = move(engine, from: (0.9, 0.3), to: (0.7, 0.3), at: 0)
        move(engine, from: (0.7, 0.3), to: (0.7, 0.7), at: time + 0.008)
        XCTAssertTrue(recorder.begins.isEmpty)
    }

    func testClickDragFromEdgeIsPointer() {
        let (engine, recorder) = makeEngine()
        engine.buttonDown = { true }
        move(engine, from: (0.95, 0.2), to: (0.95, 0.6), at: 0)
        XCTAssertTrue(recorder.begins.isEmpty)
    }

    func testSlowMoveAlongBottomDoesNotSkipTrack() {
        let (engine, recorder) = makeEngine()
        // 0.3 across in 1 s: the pointer, not a flick.
        move(engine, from: (0.8, 0.05), to: (0.5, 0.05), at: 0, steps: 125)
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    func testClimbingMoveFromBottomDoesNotSkipTrack() {
        let (engine, recorder) = makeEngine()
        move(engine, from: (0.8, 0.05), to: (0.5, 0.4), at: 0)
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    // MARK: - Recorded sessions

    func testRecordedEdgeSlides() throws {
        // 16 s of real edge use at a 12 % band: seven slides (five on the right edge,
        // two on the left), two taps on the right edge and two pointer moves in the
        // middle. The first slide starts with the finger centre drifting 2.5 %
        // inwards while the finger flattens, before it moves up.
        let (engine, recorder) = makeEngine { $0.edgeWidth = 0.12 }
        try replay("edge-slides.jsonl", into: engine)
        XCTAssertEqual(recorder.begins, [.volume, .volume, .volume, .brightness, .volume, .brightness, .volume])
        XCTAssertEqual(recorder.ends.count, 7)
        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertFalse(engine.isTrackingSlide)
    }

    func testRecordedNormalUseDoesNothing() throws {
        // 56 s of real use: pointer moves, two- and three-finger gestures, clicks
        // and a 14 s click-drag, none of them on an edge.
        let (engine, recorder) = makeEngine()
        try replay("normal-use.jsonl", into: engine)
        XCTAssertTrue(recorder.begins.isEmpty)
        XCTAssertTrue(recorder.updates.isEmpty)
        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertFalse(engine.isTrackingSlide)
    }

    func testRecordedPointerMovesInTheMiddleDoNothing() throws {
        let (engine, recorder) = makeEngine()
        try replay("pointer-middle.jsonl", into: engine)
        XCTAssertTrue(recorder.begins.isEmpty)
        XCTAssertTrue(recorder.updates.isEmpty)
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    func testFineControlUsesQuarterSteps() {
        var config = EngineConfiguration()
        config.preciseSliding = true
        config.currentVolume = 0.5
        let (engine, recorder) = makeEngine { $0 = config }

        engine.process(frame(at: 0.0, x: 0.95, y: 0.2))
        engine.process(frame(at: 0.02, x: 0.95, y: 0.25))
        guard let level = recorder.updates.last?.1 else {
            return XCTFail("expected an update")
        }
        // Quarter steps land on multiples of 1/64.
        let scaled = level * 64
        XCTAssertEqual(scaled.rounded(), scaled, accuracy: 0.0001)
    }

    func testRequiredModifierBlocksSlide() {
        let engine = SlideEngine()
        var config = EngineConfiguration()
        config.requireModifier = .option
        engine.configuration = { config }
        engine.modifiers = { [] }
        engine.buttonDown = { false }
        let recorder = Recorder()
        engine.delegate = recorder

        engine.process(frame(at: 0.0, x: 0.95, y: 0.2))
        engine.process(frame(at: 0.02, x: 0.95, y: 0.6))
        XCTAssertTrue(recorder.updates.isEmpty)
    }
}
