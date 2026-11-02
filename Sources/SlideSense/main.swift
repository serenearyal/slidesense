import AppKit
import SlideSenseCore

// Diagnostic mode: stream raw trackpad contacts to stdout.
if CommandLine.arguments.contains("--dump-touches") {
    TrackpadDiagnostics.dump()
    exit(0)
}

// Records raw frames as JSON lines: `--record-touches FILE [seconds]`.
if let index = CommandLine.arguments.firstIndex(of: "--record-touches") {
    let args = CommandLine.arguments
    guard index + 1 < args.count else {
        print("usage: SlideSense --record-touches FILE [seconds]")
        exit(1)
    }
    let seconds = index + 2 < args.count ? Double(args[index + 2]) ?? 30 : 30
    TrackpadDiagnostics.record(to: args[index + 1], seconds: seconds)
    exit(0)
}

if CommandLine.arguments.contains("--diagnose") {
    Diagnostics.printReport()
    exit(0)
}

// Development aid: cycle the HUD on screen (`--demo-hud`).
if CommandLine.arguments.contains("--demo-hud") {
    let demoApp = NSApplication.shared
    demoApp.setActivationPolicy(.accessory)
    let defaults = UserDefaults(suiteName: "io.github.slidesense.demo") ?? .standard
    let store = SettingsStore(defaults: defaults)
    let hud = HUDController(store: store)
    hud.show(edge: .volume, level: 0.64, muted: false)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        hud.show(edge: .brightness, level: 0.86, muted: false)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
        hud.dismiss()
        exit(0)
    }
    demoApp.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
