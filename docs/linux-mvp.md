# Linux Terminal MVP

This branch isolates the Linux port behind a terminal-first CLI while leaving the
existing macOS SwiftUI menu-bar app intact.

## Goal

Validate the local dictation pipeline on Linux Mint before investing in a GUI:

1. Capture microphone input as 16 kHz mono PCM WAV.
2. Transcribe the WAV with `whisper.cpp`.
3. Optionally refine the transcript with a heuristic pass or `llama.cpp`.
4. Print final text to stdout.

Desktop text insertion, global hotkeys, settings windows, and overlays are out
of scope for the first MVP.

## Current macOS Boundaries

- `SwiftUI`, `AppKit`, `NSPanel`, and menu-bar lifecycle stay macOS-only.
- `AVFoundation` audio recording is replaced by Linux recorder commands.
- `KeyboardShortcuts` global hotkeys are replaced by explicit CLI commands.
- `ApplicationServices`, `AXIsProcessTrusted`, `CGEvent`, and `NSPasteboard`
  text insertion are replaced by stdout for MVP.
- macOS Application Support model paths are replaced by XDG paths:
  `~/.local/share/voice/models`.

The portable behavior to preserve is the external process pipeline:
`whisper-cli` for transcription and `llama-cli` / `llama-completion` for
refinement.

## CLI

The MVP CLI lives at:

```bash
tools/voice-cli/voice.py
```

Run a dependency check:

```bash
python3 tools/voice-cli/voice.py doctor
```

Record audio:

```bash
python3 tools/voice-cli/voice.py record --out /tmp/voice.wav --seconds 5
```

Transcribe an existing WAV:

```bash
python3 tools/voice-cli/voice.py transcribe \
  --audio /tmp/voice.wav \
  --model ~/.local/share/voice/models/whisper/ggml-base.en.bin
```

Run the end-to-end pipeline with heuristic cleanup:

```bash
python3 tools/voice-cli/voice.py run \
  --seconds 5 \
  --whisper-model ~/.local/share/voice/models/whisper/ggml-base.en.bin \
  --refine heuristic
```

The CLI writes live phase/status output to stderr when attached to a terminal
and keeps stdout reserved for the final transcript. Use `--quiet` on any
subcommand to disable status output:

```bash
python3 tools/voice-cli/voice.py run --quiet \
  --seconds 5 \
  --whisper-model ~/.local/share/voice/models/whisper/ggml-base.en.bin \
  --refine heuristic
```

Run the end-to-end pipeline with `llama.cpp` cleanup:

```bash
python3 tools/voice-cli/voice.py run \
  --seconds 5 \
  --whisper-model ~/.local/share/voice/models/whisper/ggml-base.en.bin \
  --refine llama \
  --llama-model ~/.local/share/voice/models/llama/model.gguf
```

Launch the curses-based TUI MVP:

```bash
voice
```

The one-word launcher uses these defaults:

```bash
VOICE_WHISPER_MODEL=... # optional override; otherwise use the active TUI model
VOICE_LANGUAGE=en
VOICE_REFINE=heuristic
VOICE_WHISPER_TIMEOUT=120
VOICE_WHISPER_THREADS=4
VOICE_WHISPER_BEAM_SIZE=1
VOICE_WHISPER_BEST_OF=1
VOICE_WHISPER_FALLBACK=0
VOICE_WHISPER_MAX_CONTEXT=0
VOICE_TRIM_SILENCE=0
VOICE_TRIM_SILENCE_MS=250
VOICE_TRIM_SILENCE_THRESHOLD=-45dB
VOICE_MIN_SPEECH_SECONDS=0.25
VOICE_SECONDS=5    # only used by --auto-run or --once
VOICE_AUTO_PASTE=1 # explicit opt-in on Wayland; X11 default is on, Wayland default is off
VOICE_PASTE_DELAY_MS=120
VOICE_PASTE_TOOL=auto # auto, xdotool, wtype, or none
VOICE_HOTKEY=Ctrl+Alt+space # optional override; otherwise use saved shortcut
VOICE_SOCKET_PATH=/run/user/$UID/voice/voice.sock # optional daemon socket override
VOICE_SHORTCUT_BACKEND=auto # daemon only: auto, portal, or external
```

Override defaults with environment variables or pass additional TUI flags:

```bash
VOICE_REFINE=none voice
VOICE_SECONDS=8 voice --auto-run
VOICE_LANGUAGE=en voice
```

The CLI uses English transcription by default and saves language changes made
from the TUI language picker. Press `L` in the TUI to choose another language
or `Auto-detect`; pass `--language auto` or set `VOICE_LANGUAGE=auto` when you
need detection. It also uses fast dictation decode defaults: `--whisper-beam-size 1`,
`--whisper-best-of 1`, and `--no-whisper-fallback`, with threads set to
`min(8, CPU count)` and `--whisper-max-context 0`. Before transcription, the
pipeline trims leading and trailing silence with `ffmpeg` and skips Whisper if
the trimmed audio is too short to contain speech. Medium and Large models can
still be slow on CPU-only Mint systems; use Large v3 Turbo if available,
otherwise Small or Base, and keep `VOICE_LANGUAGE=en` if you do not need
language auto-detection.

The TUI opens at a ready screen by default. Press `r` to start recording, press
`r` again to stop, then wait for transcription and refinement. Press `M` to
open the Whisper model manager. The manager lists Tiny, Base, Small, Medium,
Large v3 Turbo, and Large v3 models from the `ggerganov/whisper.cpp` Hugging
Face repository, shows size, RAM, and speed/accuracy profile, downloads to
`~/.local/share/voice/models/whisper`, and saves the active model in
`~/.config/voice/config.json`. Press `Enter` or `D` in the manager to download
the selected model, press `A` to activate a downloaded model, and press `X` to
delete a downloaded model.

The dashboard now shows which shortcut backend is active. On X11 it can run the
built-in listener and still supports `H` to capture the next shortcut, such as
`Super+Shift+R`, saving it to `~/.config/voice/config.json`. On Wayland the TUI
shows the daemon-based path. When the desktop exposes the XDG GlobalShortcuts
portal, `voice daemon` will try to register the saved shortcut automatically; if
the portal is unavailable, bind your desktop shortcut to `voice trigger --action
toggle`. The final output is copied to the clipboard when `wl-copy`, `xclip`,
`xsel`, or an OSC 52-capable terminal is available. Auto-paste is enabled by
default on X11: on Linux Mint Cinnamon/X11 it sends `Ctrl+V` with `xdotool`
when installed, otherwise it uses a native XTest fallback through
`libX11`/`libXtst`. On Wayland the default is copy-only to avoid unexpected
Remote Desktop / input-injection prompts. Opt into Wayland paste with
`--auto-paste`, `VOICE_AUTO_PASTE=1`, or an explicit `--paste-tool wtype`.
Use `--no-auto-paste`, `VOICE_AUTO_PASTE=0`, or `--paste-tool none` to force
copy-only behavior. Press `Q` to quit. For a one-shot timed smoke test that
exits automatically using the active model:

```bash
python3 tools/voice-cli/voice.py tui --once --hold-seconds 1 \
  --seconds 5 \
  --refine heuristic
```

Run the X11 global hotkey daemon:

```bash
voice hotkey
```

Default hotkey:

```bash
Ctrl+Alt+space
```

Press the hotkey once to start recording. Press it again to stop recording,
transcribe, refine, copy the final output to the clipboard, and paste into the
focused window. The daemon keeps listening after each dictation.

Use another shortcut if Cinnamon already owns the default:

```bash
voice hotkey --hotkey Ctrl+Alt+F9
```

The hotkey backend uses X11 `XGrabKey` through `libX11`, so it does not need
root access or input-device permissions and does not observe normal typing. The
TUI shortcut recorder temporarily uses `XGrabKeyboard` only while the app is in
the `Record Shortcut` state. This is the intended path for Linux Mint Cinnamon
on X11.

Wayland does not allow arbitrary global keyboard grabs, so the built-in hotkey
daemon is X11-only. The Wayland path now runs through the background daemon:

```bash
voice daemon
```

The recommended long-running setup on Wayland is the systemd user service:

```bash
systemctl --user enable --now voice-daemon.service
```

If the desktop implements the XDG GlobalShortcuts portal, the daemon will try to
register the configured shortcut automatically. This path uses `python3-gi` for
DBus access and registers the host app id `dev.rbm.voice` so the portal can
associate Voice with `dev.rbm.voice.desktop`. If the portal is unavailable, or
if you want to force the external-command path, bind your compositor or desktop
environment shortcut to:

```bash
voice trigger --action toggle
```

Force external-command mode even when the portal exists:

```bash
voice daemon --shortcut-backend external
```

Useful manual commands:

```bash
voice model-install --recommended --profile cpu --activate
voice shortcut-status
voice service status
voice service restart
voice service logs --lines 100
systemctl --user status voice-daemon.service
systemctl --user restart voice-daemon.service
systemctl --user stop voice-daemon.service
voice trigger --action start
voice trigger --action stop
voice trigger --action status
```

Optional service overrides live in:

```bash
~/.config/voice/daemon.env
```

The installer drops a commented template there. Set values like
`VOICE_SHORTCUT_BACKEND=portal` or `VOICE_AUTO_PASTE=1`, then restart the user
service.

## Automated Setup

The recommended path is the install script:

```bash
bash tools/voice-cli/install.sh
```

This installs system packages through `apt` or `dnf`, auto-detects your GPU
(NVIDIA CUDA, Vulkan, or CPU+OpenBLAS), builds `whisper-cli` from source,
symlinks the `voice` command to `~/.local/bin`, and installs
`~/.local/share/applications/dev.rbm.voice.desktop` so Wayland portal backends
can resolve the Voice app id. It also installs `voice-daemon.service` into the
systemd user directory, writes a commented `~/.config/voice/daemon.env`
template, downloads and activates a default Whisper model, writes
`~/.config/voice/install-state.json`, and enables the service immediately when
the user manager is reachable. Re-run with `--update` to pull the latest
whisper.cpp and rebuild.

The installer now defaults to the `small` Whisper model so first-time setup
finishes faster. Override that choice if needed:

```bash
VOICE_INSTALL_MODEL_KEY=small bash tools/voice-cli/install.sh
```

The installer also supports a paired reset flow for fresh-install testing and
uninstalling:

```bash
bash tools/voice-cli/install.sh --reset --dry-run
bash tools/voice-cli/install.sh --reset
bash tools/voice-cli/install.sh --reset --remove-packages
```

`--reset` removes Voice-managed artifacts only. `--remove-packages` adds
package cleanup for the installer's known `apt` or `dnf` package set after a
single confirmation step. `--dry-run` prints the grouped reset plan without
changing anything.

After setup, launch the TUI and press `R` to record. Press `M` later only if
you want to switch away from the installer's default model.

---

## Manual / Advanced Setup

### Linux Mint base packages

```bash
sudo apt update
sudo apt install -y \
  git build-essential cmake ninja-build pkg-config ccache curl wget \
  ffmpeg sox xclip xdotool \
  libopenblas-dev libssl-dev \
  pipewire pipewire-pulse pulseaudio-utils alsa-utils \
  libasound2-dev portaudio19-dev libsdl2-dev
```

Vulkan path, recommended first for AMD GPUs and Steam Deck-class hardware:

```bash
sudo apt install -y libvulkan-dev vulkan-tools glslc
vulkaninfo
```

### Fedora base packages

```bash
sudo dnf install -y \
  git gcc gcc-c++ make cmake ninja-build pkgconf-pkg-config ccache curl wget \
  ffmpeg-free sox wl-clipboard xclip xdotool wtype \
  python3 openblas-devel pipewire-utils alsa-utils
```

Vulkan path:

```bash
sudo dnf install -y vulkan-tools vulkan-loader-devel shaderc
vulkaninfo
```

NVIDIA CUDA path:

```bash
nvidia-smi
nvcc --version
```

Install CUDA from NVIDIA's supported Ubuntu-compatible repository for the Mint
base release in use.

## Building Inference Tools

CPU baseline:

```bash
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

CUDA:

```bash
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON
cmake --build build -j
```

Vulkan:

```bash
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=1
cmake --build build -j
```

OpenBLAS CPU acceleration:

```bash
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS
cmake --build build -j
```

## Roadmap

Stage 1: Dependency validation

- Keep `voice doctor` as the first command to run on new Linux machines.
- Verify `whisper-cli`, one recorder backend, model paths, and optional GPU
  tools.

Stage 2: File transcription

- Validate `voice transcribe` against known-good WAV fixtures.
- Match the macOS app's Whisper options: no timestamps, text output, explicit
  language selection.

Stage 3: Audio capture

- Prefer `pw-record`.
- Fall back to `arecord`.
- Use `ffmpeg` when PulseAudio/PipeWire device handling is more reliable.

Stage 4: Refinement

- Use the heuristic refiner by default.
- Use `llama-completion` automatically when it exists beside `llama-cli`.
- Keep the LLM timeout bounded to avoid hung terminal sessions.

Stage 5: TUI

- TUI supports toggle recording: `R` starts, `R` stops.
- Keep the TUI state model simple: ready, recording, transcribing, refining,
  complete, and error.

Stage 6: Desktop integration

- Clipboard copy is wired through `wl-copy`, `xclip`, `xsel`, or OSC 52.
- Auto-paste sends the clipboard with `xdotool` or native XTest on X11.
- Wayland defaults to copy-only; `wtype` keyboard injection is opt-in because
  it can trigger Remote Desktop / remote interaction permission prompts.
