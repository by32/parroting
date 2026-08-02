# Architecture

## Goals

1. **CLI executable.** Single binary, launched from the terminal. No menubar, no dock icon, no settings window.
2. **Push-to-talk.** Hold Fn, speak, release — transcript appears at the cursor.
3. **Minimal recording feedback.** A small floating pill at the bottom of the screen while recording, so the user knows the mic is hot. Click-through, borderless, hidden when idle.
4. **On-device.** No network calls for transcription. Audio never leaves the machine.
5. **Pluggable models.** Whisper out of the box; Parakeet (or future engines) via a JSON-driven registry.
6. **Native and lean.** One Swift Package executable target. No sidecar processes. No HTTP servers.

## Non-goals

- Cross-platform (macOS only)
- Cloud transcription providers
- Speaker diarization, meeting recording, semantic search

## Why Swift

- **CoreML / ANE access.** WhisperKit and FluidAudio are Swift-native and run inference on the Apple Neural Engine — lower power, lower latency than CPU/GPU paths in Rust.
- **No FFI for platform APIs.** `AVAudioEngine`, `CGEventTap`, `CGEvent`, `AXIsProcessTrusted`, `NSWindow` — all first-party, no bindings to maintain.
- **Permissions plumbing** (microphone, accessibility) is dramatically smoother in a Swift binary than via Rust crates.
- **AppKit overlay for free.** The recording indicator (see below) is a borderless `NSWindow` — trivial in Swift, awkward in Rust.

The binary is a Swift Package executable — `swift build`, `swift run`, ship a single binary. Even with the overlay window, there is no `.app` bundle, no menubar entry, no dock icon.

## High-level shape

```
$ parrot
                                    ┌──────────────────┐
                                    │   ParrotCLI      │
                                    │   (main.swift)   │
                                    └────────┬─────────┘
                                             │ wires modules, runs RunLoop
                                             ▼
┌──────────────────┐  hotkey down   ┌──────────────────┐
│   HotkeyMonitor  │ ─────────────▶ │  AudioCapture    │
│  (CGEventTap)    │  hotkey up     │ (AVAudioEngine)  │
└──────────────────┘ ◀───────────── └────────┬─────────┘
                                             │ [Float] PCM
                                             ▼
                                    ┌──────────────────┐
                                    │   Transcriber    │
                                    │   (protocol)     │
                                    │  ┌────────────┐  │
                                    │  │ WhisperKit │  │
                                    │  └────────────┘  │
                                    │  ┌────────────┐  │
                                    │  │  Parakeet  │  │
                                    │  └────────────┘  │
                                    └────────┬─────────┘
                                             │ String
                                             ▼
                                    ┌──────────────────┐
                                    │  TextInjector    │
                                    │   (CGEvent)      │
                                    └──────────────────┘
```

## Modules

### `main.swift` (ParrotCLI)

Argument parsing (via `swift-argument-parser`), config loading, module wiring. Calls `NSApplication.shared.setActivationPolicy(.accessory)` so the process has no dock icon and no menu bar entry, then runs `NSApp.run()` to keep the process alive and drive the AppKit run loop (needed for `NSWindow`, `CGEventTap`, and AVFoundation). Exits cleanly on SIGINT. Logs status to stderr so a user running it in a terminal can see what's happening.

Subcommands:
- `parrot` (default) — run the daemon
- `parrot models list` — show registered models, mark which are downloaded
- `parrot models download <id>` — pre-fetch a model
- `parrot doctor` — check microphone and accessibility permissions, print remediation steps

### `HotkeyMonitor`

Global hotkey via `CGEventTap` (requires Accessibility permission). Default: **hold Fn**. Detected via `flagsChanged` events with `NSEvent.ModifierFlags.function` / `kCGEventFlagMaskSecondaryFn`. Emits `.pressed` / `.released`. Configurable via `--hotkey` flag or config file.

**Fn key caveat:** macOS by default maps the Fn (🌐) key to "Show Emoji & Symbols" or "Start Dictation" depending on the user's setting in System Settings → Keyboard → Press 🌐 key to. The CGEventTap sees the keypress regardless, but the system action also fires. `parrot doctor` will detect this setting and instruct the user to change it to "Do Nothing" so Fn becomes a clean modifier.

### `AudioCapture`

`AVAudioEngine` tap on the input node. Streams 16 kHz mono `Float32` buffers into a ring buffer while the hotkey is held. On release, hands the full buffer to the active `Transcriber`.

### `Transcriber` (protocol)

```swift
protocol Transcriber {
    func transcribe(_ audio: [Float]) async throws -> String
    var modelID: String { get }
}
```

Concrete implementations:

- `WhisperKitTranscriber` — wraps the `WhisperKit` package. CoreML, ANE-accelerated.
- `ParakeetTranscriber` — wraps `FluidAudio` (or direct CoreML) for NVIDIA Parakeet TDT.

Adding an engine = one new file conforming to `Transcriber`.

### `TextInjector`

`CGEventCreateKeyboardEvent` + `CGEventKeyboardSetUnicodeString` — pastes the transcript at the current cursor position. Works in nearly every text field on macOS (some Electron apps and secure fields are flaky; platform constraint).

### `RecordingOverlay`

A single borderless `NSWindow` displayed at the bottom-center of the active screen while recording. Provides visual feedback that the mic is hot — the only piece of UI in the app.

Window configuration:
- `styleMask: .borderless`
- `backgroundColor: .clear`, `isOpaque: false`, `hasShadow: true`
- `level: .statusBar` (or `.floating`) — sits above all other windows
- `ignoresMouseEvents = true` — clicks pass through to whatever is underneath
- `collectionBehavior: [.canJoinAllSpaces, .stationary, .ignoresCycle]` — visible across Spaces, doesn't appear in window switcher

Content: a small SwiftUI view hosted via `NSHostingView`, showing a pulsing dot + "listening" text, optionally a live mic level meter fed from `AudioCapture`. Total footprint: ~120pt wide, ~40pt tall, positioned 60pt above the bottom of the screen.

States:
- **Hidden** — idle. No window on screen.
- **Recording** — shown on `.pressed`, mic level animated.
- **Transcribing** — brief spinner state between hotkey release and text injection (usually <500 ms).
- **Hidden** — back to idle after injection.

This is the only reason the process needs an `NSApplication` run loop instead of a bare `CFRunLoop`.

### `ModelRegistry`

JSON-driven, mirrors OpenWhispr's pattern:

```swift
struct TranscriptionModel: Codable {
    let id: String              // "whisper-large-v3-turbo"
    let displayName: String
    let engine: Engine          // .whisperKit | .parakeet
    let sizeMB: Int
    let downloadURL: URL
    let languages: [String]
    let recommended: Bool
}

enum Engine: String, Codable { case whisperKit, parakeet }
```

Backed by a bundled `models.json` resource. Adding a model = appending an entry. Adding an engine = one new `Transcriber` conformance + one entry in the `Engine` enum.

The registry is the single source of truth for: download URLs, file names, sizes, recommended flags, what shows up in `parrot models list`.

### `ModelDownloader`

On first selection (or via `parrot models download <id>`), downloads to `~/Library/Application Support/parrot/models/<engine>/<id>/`. Progress bar to stderr (using `\r` overwrites). Resumable, validates size. Refuses to start the daemon if the selected model isn't present.

### `Config`

Flat TOML parser (`FlatTOML`) handles `key = value` lines with quoted keys.
Loaded from (in order): CLI flags > `~/.config/parrot/config.toml` > defaults.

```toml
model = "whisper-large-v3-turbo"
hotkey = "fn"
language = "auto"
sensitivity = "normal"
overlay = true
refine = "off"           # off, local, cloud
refine-style = "formal"
```

The menu bar settings dropdown writes back to this file via `Config.toTOML()` +
`Config.write()`. A `ConfigWatcher` reopens the file descriptor after each
event (atomic writes replace the inode) and calls `Daemon.applyConfig` to
apply changes live — sensitivity, refine mode, refine style, and styles
update without restart. Hotkey, model, and language changes require restart.

## Permissions

Two prompts on first run, both surfaced via `parrot doctor`:

1. **Microphone** — standard `AVCaptureDevice` request, fires on first audio engine start.
2. **Accessibility** — required for `CGEventTap` (hotkey) and `CGEvent` posting (text injection). User toggles in System Settings → Privacy & Security → Accessibility, granting the *terminal* (or whatever launched parrot) permission, since the binary inherits its parent's TCC identity.

`parrot doctor` checks both and prints actionable next steps if either is missing. Without these, the daemon refuses to start.

### TCC quirk worth knowing

When you launch `parrot` from `Terminal.app`, accessibility permission is granted to *Terminal*, not parrot itself. This means:
- Switching terminals (Terminal → iTerm → Ghostty) requires re-granting permission.
- Running under `launchd` requires granting permission to whatever spawns it.

This is a macOS platform behavior, not a parrot bug. `parrot doctor` will identify the parent process and tell the user which app needs the permission.

## Models — what ships

Initial registry:

| Engine | Model | Size | Notes |
|---|---|---|---|
| WhisperKit | `whisper-base.en` | ~80 MB | Fast, English only, low resource |
| WhisperKit | `whisper-large-v3-turbo` | ~800 MB | Recommended for daily use |
| Parakeet | `parakeet-tdt-0.6b-v3` | ~600 MB | English, fastest on ANE |

Models live in `~/Library/Application Support/parrot/models/`. Not bundled — fetched on first selection or via `parrot models download`.

## Data flow, end-to-end

1. User runs `parrot` in a terminal.
2. `ParrotCLI` validates permissions (`parrot doctor` logic), loads config, instantiates modules.
3. Sets `.accessory` activation policy and enters `NSApp.run()`. Status: `listening`. Overlay hidden.
4. User holds Fn.
5. `HotkeyMonitor` fires `.pressed`. `RecordingOverlay` shows. Status: `recording`.
6. `AudioCapture` starts the AVAudioEngine tap. Buffers fill. Overlay animates mic level.
7. User releases Fn.
8. `HotkeyMonitor` fires `.released`. Overlay switches to spinner. Status: `transcribing`.
9. `AudioCapture` stops, hands buffer to active `Transcriber`.
10. `Transcriber` runs CoreML inference. Returns string.
11. `TextInjector` posts the string at the cursor.
12. Overlay hides. Status: `listening`. Loop.
13. User hits `^C`. Process exits cleanly.

End-to-end latency target: <500 ms after hotkey release for utterances under 10 seconds, on Apple Silicon.

## What we are deliberately NOT building

- No streaming partial transcripts in v1. Press, speak, release, get full text.
- No VAD-based hands-free mode. Push-to-talk is more reliable and uses zero idle CPU.
- No history, transcript log, or clipboard manager. Output goes to the cursor and that's it.
- No speaker diarization, meeting recording, or semantic search.

## Project layout (planned)

Organized by feature area. These are folders within a single SPM executable target — Swift sees them as one module, but the directory grouping keeps related code together. If a group later earns its keep as a reusable library (e.g. `Transcription` consumed by another tool), it can be promoted to its own SPM target with no rewriting.

```
parrot/
  Package.swift                 # SPM, single executable target
  Sources/parrot/
    main.swift                  # entry point, argument parsing, NSApp.run()
    Config.swift
    Doctor.swift

    Transcription/              # the inference layer
      Transcriber.swift         # protocol
      WhisperKitTranscriber.swift
      ParakeetTranscriber.swift

    Models/                     # registry + download pipeline
      ModelRegistry.swift
      ModelDownloader.swift
      TranscriptionModel.swift  # Codable types

    Audio/
      AudioCapture.swift        # AVAudioEngine tap + ring buffer

    Input/
      HotkeyMonitor.swift       # CGEventTap
      TextInjector.swift        # CGEvent posting

    UI/
      RecordingOverlay.swift    # borderless NSWindow + SwiftUI pill

  Resources/
    models.json
  docs/
    architecture.md
  README.md
```

Build: `swift build -c release`. Resulting binary at `.build/release/parrot`. Install: copy to `~/.local/bin/` or `/usr/local/bin/`.

## Packaging

`.github/workflows/release.yml` runs on a `v*` tag and produces two artifacts from one binary:

| Artifact | Channel | Identity |
| --- | --- | --- |
| `parrot-macos-arm64.tar.gz` | `curl \| sh`, `brew install by32/tap/parrot` | unsigned; ad-hoc cdhash |
| `Parrot-<version>-arm64.dmg` | `brew install --cask by32/tap/parrot`, direct download | Developer ID, notarized, stapled |

The scripts are independently runnable so packaging can be debugged without pushing a tag:

- `scripts/verify-binary.sh` — asserts the build is arm64 and actually links `FoundationModels`. `LocalRefiner` sits behind `#if canImport(FoundationModels)`, so building against a pre-macOS-26 SDK silently compiles it away and `--refine local` fails at runtime. This turns that into a build failure.
- `scripts/bundle-app.sh` — assembles `Parrot.app` from `packaging/Info.plist`, and cross-checks that the binary's `--version` matches the version being stamped in.
- `scripts/sign-notarize.sh` — signs with Hardened Runtime, notarizes, staples, and builds the DMG. Auto-discovers a `Developer ID Application` identity, and refuses to proceed with an Apple Distribution or Apple Development cert since Gatekeeper rejects those for direct distribution.
- `scripts/install-local.sh` — build, sign, and install to `/Applications` in one step, for working on the daemon locally. Notarization is skipped deliberately: it exists so *other* Macs will run a downloaded app and does nothing for one you signed and run yourself.

### Signing locally is not optional

Running an unsigned local build costs you the Accessibility grant on every rebuild, so `install-local.sh` signs with whatever it can find, preferring `Developer ID Application` and falling back to `Apple Development`. The fallback is enough for local use because TCC matches on the *designated requirement*, and for any real certificate that requirement names the bundle ID and the signing cert rather than the code:

```
identifier "io.github.by32.parroting" and anchor apple generic
  and certificate leaf[subject.CN] = "Apple Development: ..." and ...
```

Ad-hoc signing (`codesign -s -`) produces `cdhash H"..."` instead, which pins one exact build and so behaves no better than not signing. The script extracts the requirement and refuses to install if it contains a cdhash. Note that `codesign -d -r-` *comments out* the line for an ad-hoc signature (`# designated => ...`), so the parser has to tolerate the leading `#` — without that the check reads empty and silently passes.

An `Apple Development` cert expires in about a year and Gatekeeper rejects it on other machines, so it is a local-development answer only; distribution still needs Developer ID plus notarization.

Signing is conditional on the `MACOS_CERT_P12` secret. Without it the workflow still publishes the unsigned tarball, so the CLI channel never depends on certificate availability.

### Why a bundle exists at all

Parrot is a single binary, so an `.app` is pure overhead except for one thing: TCC. macOS keys an Accessibility grant to the requesting process's code-signing identity, which for an unsigned binary degrades to its cdhash. Upgrading changes the hash, silently invalidating the grant while leaving the checkbox ticked — the daemon runs, the event tap installs, and no keystrokes arrive.

A Developer ID signature gives a stable identity across versions, so the grant persists. `LoginItem.mechanism` picks `SMAppService` over the LaunchAgent plist when running inside the bundle, because a plist that execs the bundle's inner binary would start it as a bare process and forfeit that identity.

Two entries in `packaging/` are load-bearing and easy to mistake for boilerplate:

- `NSMicrophoneUsageDescription` in `Info.plist` — a bundled app that requests the microphone without it is terminated rather than prompted.
- `com.apple.security.device.audio-input` in `parrot.entitlements` — Hardened Runtime, which notarization requires, denies microphone access without it even though the app is not sandboxed.

### On Swift "modules"

Swift's module unit is the **SPM target** (one target = one module = one `import` namespace). For parrot v1 we use a single executable target with the folder structure above; everything is in the same module so no `import` statements between files. If we ever want enforced boundaries (e.g. `Transcription` and `UI` shouldn't reach into `Audio` internals), we promote folders to separate targets in `Package.swift` — a structural change, not a semantic one.

## Open questions

- **Parakeet via FluidAudio vs. direct CoreML?** FluidAudio is faster to integrate but adds a dependency. Decide once we benchmark both.
- **Hotkey conflicts.** Right-Option is unused on most keyboards but some users remap it. Print a clear error if `CGEventTap` registration fails.
- **First-run UX.** Bundle `whisper-base.en` so `parrot` works out of the box, or always require an explicit download? Probably the latter — keeps the binary small and the model directory clean.
- **App icon.** `packaging/Parrot.icns` is picked up if present; there is none yet, so the bundle shows the generic app icon.
- **License.** There is no `LICENSE` file, which blocks Homebrew core submission and leaves redistribution terms unstated.
