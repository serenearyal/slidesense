# Contributing to SlideSense

Thanks for taking a look. Bug reports, edge-case trackpad data and pull requests
are all welcome.

## Good first issues

- A trackpad whose vertical axis is reported the other way round (the **Flip
  vertical edges** setting exists for this — telling us your model helps).
- Magic Mouse support: `TrackpadMonitor` already enumerates every multitouch
  device; the missing piece is choosing the right edge geometry per device.
- Copy review of the settings footnotes and the README.

## Getting set up

```bash
git clone https://github.com/shashvat1965/slidesense.git
cd slidesense
swift build          # or: make build
make test            # gesture engine, HUD layout, settings window, menu
make run             # builds SlideSense.app and opens it
```

You need macOS 13 or later and a Swift 6 toolchain (Xcode 16+ is easiest). There
are no third-party dependencies.

`make app` assembles `SlideSense.app` in the repository root, unsigned. Because
every rebuild replaces the binary, macOS may ask for Accessibility again — that
is expected, not a bug.

## How the code is organised

```
Sources/SlideSenseCore/
  Model/       Settings, edge geometry, SlideEngine (pure, fully unit-tested)
  Multitouch/  dlopen bindings for MultitouchSupport + TrackpadMonitor
  System/      CoreAudio, DisplayServices, media keys, haptics, permissions
  UI/          Menu bar item, settings window, HUD
Sources/SlideSense/     entry point, --dump-touches, --record-touches, --diagnose, --demo-hud
Tests/SlideSenseCoreTests/
```

Two rules keep this maintainable:

1. **Hardware behind a protocol.** Anything that talks to the system (`LevelController`,
   `StatusItemDataSource`, `PermissionState`) is injectable, so tests never touch
   real hardware.
2. **Gestures are data.** `SlideEngine` takes `TouchFrame`s and emits events; no
   AppKit, no I/O. If you add a gesture, add frames to
   `Tests/SlideSenseCoreTests/SlideEngineTests.swift` instead of testing by hand.

## Testing the UI

`make test` runs the full suite. For visual changes run:

```bash
make snapshots
open Snapshots
```

That renders, at 2×, the HUD in nine states (0 %, 1 %, 50 %, 100 %, muted,
brightness and the three media glyphs, light and dark) plus all four settings
tabs in both appearances. Review the images, then commit only what changed.

There are exact layout assertions too — panel 210 × 60, bar at (48, 26, 148 × 8),
settings content 540 × 546, every control on the same trailing edge. If you
change a metric on purpose, update `HUDMetrics`/`Layout` and the expectation
together.

## Debugging on real hardware

```bash
swift run SlideSense --diagnose      # framework, permission, volume/brightness state
swift run SlideSense --dump-touches  # raw contacts: id, x, y, touch state
swift run SlideSense --demo-hud      # cycles the HUD on screen
```

`--dump-touches` prints normalised coordinates with `y` pointing towards the
screen. If an edge feels inverted on your Mac, note your model and what you saw
in the issue — it usually means the vertical axis needs flipping.

To turn a gesture problem into a test, record it:
`swift run SlideSense --record-touches touches.jsonl 30` writes 30 seconds of raw
frames as JSON lines. Put the file in `Tests/SlideSenseCoreTests/Fixtures/` and
replay it in `SlideEngineTests` with `replay(_:into:)`.

## Pull requests

- One focused change per PR, with a sentence on *why* in the description.
- `make test` must pass; add a test for behaviour that is not already covered.
- Match the surrounding style: 4-space indent, `// MARK:` sections, doc comments
  on types, no force-unwraps on user-facing data, no third-party packages.
- Do not add network calls, analytics or telemetry. The app is deliberately
  offline.
- UI changes should keep the native macOS look: system fonts and colours, no
  custom chrome, no tick marks under sliders.

Commit messages: a short imperative subject (`Fix …`, `Add …`), then the reason
in the body if it is not obvious.

## Reporting a bug

Use the bug report template and include the output of `swift run SlideSense
--diagnose`, your Mac model and macOS version. That covers most of what is needed
to reproduce a gesture or brightness problem.
