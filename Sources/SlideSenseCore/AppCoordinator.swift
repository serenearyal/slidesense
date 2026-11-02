import AppKit
import Foundation

/// Wires the touch pipeline, the system controllers and the UI together.
public final class AppCoordinator: NSObject, StatusItemDataSource {
    private let store: SettingsStore
    private let engine = SlideEngine()
    private let monitor = TrackpadMonitor()
    private let audio = AudioController.shared
    private let brightness = BrightnessController.shared
    private let hud: HUDController
    private let freezer = CursorFreezer()

    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController!

    private let snapshotLock = NSLock()
    private var snapshot = EngineConfiguration()

    private var observers: [NSObjectProtocol] = []
    private var lastTouchRefresh: TimeInterval = 0
    /// Frames arrive on the trackpad thread, resets come from the main thread.
    /// This lock guards the engine and the pointer state between them.
    private let pipelineLock = NSLock()
    private var frozen = false
    private var pendingAnchor: CGPoint?
    private var freezeCursorEnabled = true
    private var hapticsEnabled = true
    private var hapticStrength: HapticStrength = .medium
    private var lastLoginItemPreference: Bool?

    public init(store: SettingsStore = .shared) {
        self.store = store
        self.hud = HUDController(store: store)
        super.init()
    }

    // MARK: - Lifecycle

    public func start() {
        statusItem = StatusItemController(store: store, dataSource: self)
        settingsWindow = SettingsWindowController(store: store)

        engine.delegate = self
        engine.configuration = { [weak self] in self?.currentSnapshot() ?? EngineConfiguration() }
        engine.modifiers = { .current }

        monitor.onFrame = { [weak self] frame in self?.handle(frame) }
        monitor.flipVertical = store.settings.flipVerticalEdges

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .slideSenseSettingsDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.settingsDidChange()
            }
        )

        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                // The framework's device handle dies with sleep; pick the
                // trackpad back up once the Mac is awake again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if self.store.settings.enabled { self.monitor.restart() }
                }
            }
        )

        refreshSnapshot()
        if store.settings.enabled {
            startMonitoring()
        }

        lastLoginItemPreference = store.settings.openAtLogin
        LoginItem.sync(store.settings.openAtLogin)

        audio.onChange = { [weak self] in self?.levelsDidChange() }
        audio.startObserving()

        statusItem.willOpen = { [weak self] in self?.refreshLevelsNow() }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.settingsWindow?.refreshPermissionState()
            }
        )

        if !AccessibilityPermission.isTrusted {
            AccessibilityPermission.requestIfNeeded()
        }

        if !store.settings.hasCompletedSetup {
            settingsWindow.show()
        }
    }

    public func stop() {
        audio.onChange = nil
        audio.stopObserving()
        statusItem?.willOpen = nil
        monitor.stop()
        resetPipeline()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    // MARK: - Touch pipeline

    private func handle(_ frame: TouchFrame) {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }

        // A slide starts from the live system level. Levels are cached and kept
        // fresh by the CoreAudio/DisplayServices callbacks, but re-read once when
        // a finger lands so a change made without a notification cannot make the
        // slide jump. Nothing here runs while the pad is untouched.
        if !engine.isTrackingSlide, frame.activeContacts.count == 1,
           frame.timestamp - lastTouchRefresh > 0.25 {
            lastTouchRefresh = frame.timestamp
            brightness.refresh()
            refreshSnapshot()
        }

        engine.process(frame)

        if engine.isTrackingSlide {
            if !frozen {
                frozen = true
                if freezeCursorEnabled { freezer.begin(at: pendingAnchor) }
            }
            if freezeCursorEnabled { freezer.hold() }
            return
        }
        if frozen {
            frozen = false
            freezer.end()
        }
        // Remember where the pointer was when the finger landed on an edge, so a
        // slide puts it back there, not where its first millimetres moved it.
        if engine.isPendingSlide {
            if pendingAnchor == nil { pendingAnchor = CGEvent(source: nil)?.location }
        } else {
            pendingAnchor = nil
        }
    }

    /// Drops any gesture and gives the pointer back.
    private func resetPipeline() {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        engine.reset()
        pendingAnchor = nil
        if frozen {
            frozen = false
            freezer.end()
        }
    }

    private func startMonitoring() {
        if !monitor.start() {
            NSLog("SlideSense: no multitouch device found — will retry when the trackpad reconnects.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.store.settings.enabled, !self.monitor.isRunning else { return }
                self.startMonitoring()
            }
        }
    }

    // MARK: - Configuration

    private func refreshSnapshot() {
        let settings = store.settings
        var new = EngineConfiguration()
        new.leftEdge = settings.leftEdge
        new.rightEdge = settings.rightEdge
        new.edgeWidth = settings.edgeWidth
        new.bottomQuarterOnly = settings.bottomQuarterOnly
        new.sensitivity = settings.sensitivity
        new.currentBrightness = brightness.level
        new.currentVolume = audio.level
        new.mediaStripEnabled = settings.mediaStripEnabled
        new.mediaStripReverse = settings.mediaStripReverse
        new.quickMuteEnabled = settings.quickMuteEnabled
        new.tapToPlayEnabled = settings.tapToPlayEnabled
        new.requireModifier = settings.requireModifier
        new.fineControlWithModifiers = settings.fineControlWithModifiers
        new.preciseSliding = settings.preciseSliding

        snapshotLock.lock()
        snapshot = new
        snapshotLock.unlock()

        freezeCursorEnabled = settings.freezeCursor
        hapticsEnabled = settings.hapticsEnabled
        hapticStrength = settings.hapticStrength
        monitor.flipVertical = settings.flipVerticalEdges
    }

    private func currentSnapshot() -> EngineConfiguration {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot
    }

    private func settingsDidChange() {
        refreshSnapshot()

        let settings = store.settings
        if settings.enabled {
            if !monitor.isRunning { startMonitoring() }
        } else {
            monitor.stop()
            resetPipeline()
        }

        if lastLoginItemPreference != settings.openAtLogin {
            lastLoginItemPreference = settings.openAtLogin
            LoginItem.sync(settings.openAtLogin)
        }

        statusItem?.refresh()
    }

    /// CoreAudio or DisplayServices reported a change (including our own).
    private func levelsDidChange() {
        refreshSnapshot()
        statusItem?.refresh()
    }

    /// Called just before the menu is displayed, so the readouts are exact.
    private func refreshLevelsNow() {
        audio.refresh()
        brightness.refresh()
        refreshSnapshot()
        statusItem?.refresh()
    }

    // MARK: - StatusItemDataSource

    public var volumeLevel: Double { audio.level }
    public var brightnessLevel: Double { brightness.level }
    public var isMuted: Bool { audio.isMuted }
    public var accessibilityGranted: Bool { AccessibilityPermission.isTrusted }

    public func requestSettings() {
        settingsWindow.show()
        settingsWindow.refreshPermissionState()
    }

    public func requestAccessibility() {
        if !AccessibilityPermission.isTrusted {
            AccessibilityPermission.requestIfNeeded()
        }
        AccessibilityPermission.openSystemSettings()
    }

    public func requestQuit() {
        NSApp.terminate(nil)
    }
}

// MARK: - SlideEngineDelegate

extension AppCoordinator: SlideEngineDelegate {
    public func slideEngine(_ engine: SlideEngine, didBeginSlide target: EdgeAction) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hud.show(edge: target, level: self.level(for: target), muted: self.audio.isMuted)
        }
    }

    public func slideEngine(_ engine: SlideEngine, didUpdateSlide target: EdgeAction, level: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch target {
            case .volume:
                self.audio.setLevel(level)
                self.hud.show(edge: .volume, level: self.audio.level, muted: self.audio.isMuted)
            case .brightness:
                self.brightness.setLevel(level)
                self.hud.show(edge: .brightness, level: self.brightness.level, muted: false)
            }
        }
    }

    public func slideEngine(_ engine: SlideEngine, didEndSlide target: EdgeAction, level: Double) {
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.refresh()
            self?.refreshSnapshot()
        }
    }

    public func slideEngine(_ engine: SlideEngine, didTick target: EdgeAction, level: Double) {
        guard hapticsEnabled else { return }
        Haptics.shared.tick(hapticStrength)
    }

    public func slideEngine(_ engine: SlideEngine, didRecognize command: MediaCommand) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch command {
            case .playPause:
                MediaKeyController.shared.send(.playPause)
                self.hud.showMedia(.playPause)
            case .next:
                MediaKeyController.shared.send(.next)
                self.hud.showMedia(.next)
            case .previous:
                MediaKeyController.shared.send(.previous)
                self.hud.showMedia(.previous)
            case .mute:
                self.audio.toggleMute()
                if self.hapticsEnabled {
                    Haptics.shared.buzz(self.hapticStrength)
                }
                self.hud.show(edge: .volume, level: self.audio.level, muted: self.audio.isMuted)
                self.statusItem?.refresh()
            }
        }
    }

    private func level(for target: EdgeAction) -> Double {
        switch target {
        case .volume: return audio.level
        case .brightness: return brightness.level
        }
    }
}
