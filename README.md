# parrot

A minimal macOS dictation daemon. Push-to-talk, on-device transcription, text inserted at the cursor.

## Install

```sh
curl -fsSL https://digimata.github.io/parrot/install.sh | sh
parrot setup                       # grants mic + accessibility, downloads the model
parrot install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML — so the installer refuses to run on Intel.

The installer drops the binary in `/usr/local/bin/parrot`. Builds are unsigned for now, so the installer strips the quarantine xattr — once you've inspected the script you'll see exactly what it does.

## How to use

1. **Run it.** Either `parrot install --launch-at-login` (daemonized, runs forever, lives in the menu bar), or `parrot` in any terminal tab.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold the `fn` key, speak, release.** A small pill appears at the bottom of the screen while the mic is hot.
4. **The transcript types itself in at the cursor** when you release. Usually within 200-300ms.

That's it. There is no record button, no stop button, no "send" — `fn` is the whole interface.

> **Note:** on most modern Macs the `fn` key is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols," `parrot setup` will tell you how to flip it back to plain `fn`.

## CLI

```sh
parrot                                 # run in the foreground (^C to quit)
parrot setup                           # one-time setup: permissions + model download
parrot install --launch-at-login       # register a LaunchAgent (background daemon)
parrot install --uninstall             # remove the LaunchAgent
parrot doctor                          # check permissions + fn key setting
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --hotkey right-option           # change the push-to-talk key
                                       # (fn, right-option, right-command)
parrot --language auto                 # transcribe in 100+ languages (default: en)
parrot --sensitivity high              # whispered dictation (default: normal)
parrot --refine local                  # AI cleanup via on-device model (default: off)
parrot --refine cloud                  # AI cleanup via OpenAI-compatible endpoint
parrot --refine-style formal           # tone instruction for the refiner
parrot --no-overlay                    # disable the bottom-of-screen pill
```

## Config

Optional. Defaults are fine; edit `~/.config/parrot/config.toml` to make a flag stick:

```toml
model = "whisper-large-v3-turbo"
hotkey = "fn"            # fn, right-option, right-command
language = "auto"        # auto or a Whisper code like en, es, fr
sensitivity = "normal"   # normal or high (for whispered dictation)
overlay = true           # bottom-of-screen recording pill
refine = "off"           # off, local (on-device), or cloud
refine-style = "formal"  # tone instruction: formal, casual, concise, etc.
```

CLI flags override the file, the file overrides the defaults. The menu bar
settings dropdown also writes back to this file, so changes made there
persist across restarts. Editing the file while the daemon runs is picked
up automatically.

## Personal dictionary

`~/.config/parrot/dictionary.txt` teaches parrot your vocabulary:

```text
# Bare lines become Whisper bias terms — the model is more likely
# to use that spelling:
Kubernetes
Grafana

# "heard -> wanted" lines rewrite the transcript after the fact:
see quel -> SQL
kuber netes -> Kubernetes
```

Corrections match case-insensitively on whole words only, so a rule for
"netes" cannot fire inside "kubernetes."

## Snippets

`~/.config/parrot/snippets.toml` maps a spoken cue to canned text:

```toml
"my calendar link" = "https://cal.example/me"
"standup intro" = "Morning! Quick update:"
```

Say the cue as a whole utterance and the expansion is injected instead.
Cue matching ignores case, trailing punctuation, and whitespace.

## Per-app styles

`~/.config/parrot/styles.toml` maps app bundle IDs to refine tone
instructions, so Mail can be formal while Messages is casual:

```toml
"com.apple.mail" = "formal"
"com.apple.MobileSMS" = "casual"
```

A per-app match overrides the global `refine-style`. The frontmost app is
captured at hotkey release, so switching windows mid-transcribe does not
change which style applies.

## Refine

The refine engine cleans up raw transcripts — filler words, false starts,
punctuation — before the text reaches the cursor.

- **`local`**: Apple's on-device language model (FoundationModels). Private,
  free, no network. Requires macOS 26 with Apple Intelligence enabled.
- **`cloud`**: any OpenAI-compatible chat-completions endpoint. Stronger,
  but sends transcript text off-machine. Set the
  `PARROT_REFINE_API_KEY` environment variable to enable; the key is never
  written to config.

Refine is off by default. Enable it via `--refine`, the config file, or the
menu bar dropdown.

## Menu bar

Click the parrot icon in the menu bar for:

- Recording/transcription status and model info
- **Settings** submenu: refine mode, sensitivity, and refine style with
  inline dropdown controls — changes apply live and persist to config.toml
- Quit

## Stack

- **Swift** — single SPM executable target
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **FoundationModels** — on-device AI transcript cleanup (macOS 26+)
- **AVAudioEngine** — mic capture
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — recording-indicator pill
- **NSStatusItem** — menu bar icon with settings dropdown

See [docs/architecture.md](docs/architecture.md) for design notes.

## Build from source

```sh
swift build -c release
.build/release/parrot --help
```
