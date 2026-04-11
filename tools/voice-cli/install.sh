#!/usr/bin/env bash
# install.sh — single-command Linux setup for Voice
#
# Usage:
#   bash tools/voice-cli/install.sh                            # first install
#   bash tools/voice-cli/install.sh --update                   # pull latest whisper.cpp + rebuild
#   bash tools/voice-cli/install.sh --reset                    # remove Voice-managed artifacts
#   bash tools/voice-cli/install.sh --reset --remove-packages  # also remove installer-known packages
#   bash tools/voice-cli/install.sh --reset --dry-run          # print reset plan only

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve script and repo root (symlink-safe, same pattern as voice wrapper)
# ---------------------------------------------------------------------------
SOURCE="${BASH_SOURCE[0]}"
while [ -L "${SOURCE}" ]; do
  SCRIPT_DIR="$(cd -- "$(dirname -- "${SOURCE}")" && pwd)"
  TARGET="$(readlink -- "${SOURCE}")"
  if [[ "${TARGET}" == /* ]]; then
    SOURCE="${TARGET}"
  else
    SOURCE="${SCRIPT_DIR}/${TARGET}"
  fi
done
SCRIPT_DIR="$(cd -- "$(dirname -- "${SOURCE}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# Path constants
# ---------------------------------------------------------------------------
VOICE_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/voice"
VOICE_MODEL_ROOT="${VOICE_DATA_DIR}/models"
WHISPER_MODEL_DIR="${VOICE_MODEL_ROOT}/whisper"
WHISPER_SRC_PARENT_DIR="${VOICE_DATA_DIR}/src"
WHISPER_SRC_DIR="${WHISPER_SRC_PARENT_DIR}/whisper.cpp"
WHISPER_BUILD_DIR="${WHISPER_SRC_DIR}/build"
WHISPER_BIN="${WHISPER_BUILD_DIR}/bin/whisper-cli"
WHISPER_BUILD_FLAGS_FILE="${WHISPER_BUILD_DIR}/.voice-cmake-flags"
WHISPER_CMAKE_CACHE_FILE="${WHISPER_BUILD_DIR}/CMakeCache.txt"
LOCAL_BIN="${HOME}/.local/bin"
LOCAL_APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
VOICE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/voice"
VOICE_CONFIG_FILE="${VOICE_CONFIG_DIR}/config.json"
VOICE_INSTALL_STATE_FILE="${VOICE_CONFIG_DIR}/install-state.json"
if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
  VOICE_RUNTIME_DIR="${XDG_RUNTIME_DIR}/voice"
else
  VOICE_RUNTIME_DIR="/tmp/voice-$(id -u)"
fi
VOICE_SOCKET_PATH="${VOICE_RUNTIME_DIR}/voice.sock"
VOICE_WRAPPER="${REPO_ROOT}/tools/voice-cli/voice"
VOICE_DESKTOP_FILE="${REPO_ROOT}/tools/voice-cli/voice.desktop"
VOICE_DAEMON_SERVICE_FILE="${REPO_ROOT}/tools/voice-cli/voice-daemon.service"
VOICE_DAEMON_ENV_EXAMPLE="${REPO_ROOT}/tools/voice-cli/daemon.env.example"
WHISPER_REPO="https://github.com/ggerganov/whisper.cpp.git"

VOICE_SERVICE_NAME="voice-daemon.service"
VOICE_PORTAL_DESKTOP_ID="dev.rbm.voice.desktop"

# ---------------------------------------------------------------------------
# Package definitions
# ---------------------------------------------------------------------------
APT_CORE_PACKAGES=(
  git build-essential cmake ninja-build pkg-config ccache curl wget
  ffmpeg sox xclip xdotool wl-clipboard python3 python3-gi
  libopenblas-dev
)
APT_OPTIONAL_PACKAGES=(
  wtype
  vulkan-tools
  libvulkan-dev
  glslc
)
APT_AUDIO_FALLBACK_PACKAGES=(
  alsa-utils
)
APT_RETAINED_PACKAGES=(
  git
  python3
  python3-gi
  curl
  wget
  build-essential
  cmake
  ninja-build
  pkg-config
  ccache
  ffmpeg
  sox
  libopenblas-dev
  alsa-utils
)

DNF_CORE_PACKAGES=(
  git gcc gcc-c++ make cmake ninja-build pkgconf-pkg-config ccache curl wget
  ffmpeg-free sox wl-clipboard xclip xdotool python3 python3-gobject
  openblas-devel pipewire-utils alsa-utils
)
DNF_OPTIONAL_PACKAGES=(
  wtype
  vulkan-tools
  vulkan-loader-devel
  shaderc
  glslc
)
DNF_RETAINED_PACKAGES=(
  git
  python3
  python3-gobject
  curl
  wget
  gcc
  gcc-c++
  make
  cmake
  ninja-build
  pkgconf-pkg-config
  ccache
  ffmpeg-free
  sox
  openblas-devel
  pipewire-utils
  alsa-utils
)

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
PACKAGE_MANAGER=""
DISTRO_LABEL=""
SESSION_LABEL=""
RECOMMENDED_MODEL_KEY=""
CMAKE_GPU_FLAGS=""
GPU_LABEL=""

UPDATE=0
RESET=0
REMOVE_PACKAGES=0
DRY_RUN=0
ASSUME_YES=0

INSTALL_PACKAGES=()
RETAINED_SHARED_PACKAGES=()
REMOVABLE_PACKAGE_CANDIDATES=()

RESET_PLAN_SOURCE="heuristic"
RESET_MANAGED_PATHS=()
RESET_ARTIFACTS=()
RESET_PRUNE_DIRS=()
RESET_PACKAGE_CANDIDATES=()
RESET_RETAINED_PACKAGES=()
RESET_SERVICE_ACTIONS=()

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
for arg in "$@"; do
  case "${arg}" in
    --update) UPDATE=1 ;;
    --reset) RESET=1 ;;
    --remove-packages) REMOVE_PACKAGES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --help|-h)
      echo "Usage: bash tools/voice-cli/install.sh [--update]"
      echo "       bash tools/voice-cli/install.sh --reset [--remove-packages] [--dry-run] [--yes]"
      echo ""
      echo "Install mode:"
      echo "  (no flags)       Install system packages, build whisper.cpp, provision a default model,"
      echo "                   wire the voice command, and enable the user service."
      echo "  --update         Pull the latest whisper.cpp and rebuild before installing."
      echo ""
      echo "Reset mode:"
      echo "  --reset          Remove Voice-managed artifacts for fresh-install testing or uninstalling."
      echo "  --remove-packages"
      echo "                   Also remove installer-known distro packages after confirmation."
      echo "  --dry-run        Print the reset plan without changing anything."
      echo "  --yes            Skip the confirmation prompt."
      echo ""
      echo "Env override: VOICE_INSTALL_MODEL_KEY=base|small|large-v3-turbo ..."
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      echo "Run with --help for usage." >&2
      exit 1
      ;;
  esac
done

if [[ "${UPDATE}" -eq 1 && "${RESET}" -eq 1 ]]; then
  echo "Cannot combine --update with --reset." >&2
  exit 1
fi

if [[ "${REMOVE_PACKAGES}" -eq 1 && "${RESET}" -eq 0 ]]; then
  echo "--remove-packages only applies with --reset." >&2
  exit 1
fi

if [[ "${DRY_RUN}" -eq 1 && "${RESET}" -eq 0 ]]; then
  echo "--dry-run only applies with --reset." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Print helpers
# ---------------------------------------------------------------------------
_tty_bold=""
_tty_reset=""
_tty_green=""
_tty_yellow=""
_tty_cyan=""
if [[ -t 1 ]]; then
  _tty_bold="\033[1m"
  _tty_reset="\033[0m"
  _tty_green="\033[32m"
  _tty_yellow="\033[33m"
  _tty_cyan="\033[36m"
fi

step()  { printf "${_tty_bold}${_tty_cyan}[voice]${_tty_reset} %s\n" "$*"; }
ok()    { printf "${_tty_bold}${_tty_green}[voice]${_tty_reset} %s\n" "$*"; }
warn()  { printf "${_tty_bold}${_tty_yellow}[voice] warning:${_tty_reset} %s\n" "$*" >&2; }
die()   { printf "${_tty_bold}\033[31m[voice] error:${_tty_reset} %s\n" "$*" >&2; exit 1; }

print_list() {
  local item=""
  for item in "$@"; do
    printf "  - %s\n" "${item}"
  done
}

append_unique() {
  local array_name="$1"
  local value="$2"
  declare -n array_ref="${array_name}"
  local existing=""
  for existing in "${array_ref[@]:-}"; do
    if [[ "${existing}" == "${value}" ]]; then
      return 0
    fi
  done
  array_ref+=("${value}")
}

array_contains() {
  local needle="$1"
  shift
  local item=""
  for item in "$@"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

json_quote() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

json_array_from_args() {
  local first=1
  local item=""
  printf '['
  for item in "$@"; do
    if [[ "${first}" -eq 0 ]]; then
      printf ', '
    fi
    first=0
    json_quote "${item}"
  done
  printf ']'
}

run_with_keepalive() {
  local label="$1"
  shift

  local interval="${VOICE_INSTALL_KEEPALIVE_SECONDS:-1}"
  local log_interval="${VOICE_INSTALL_LOG_INTERVAL_SECONDS:-30}"
  local elapsed=0
  local next_log="${log_interval}"
  local spinner='|/-\'
  local spinner_index=0
  local interactive=0

  if [[ -t 2 ]]; then
    interactive=1
  fi

  "$@" &
  local cmd_pid=$!

  while kill -0 "${cmd_pid}" >/dev/null 2>&1; do
    sleep "${interval}"
    elapsed=$((elapsed + interval))
    if kill -0 "${cmd_pid}" >/dev/null 2>&1; then
      if [[ "${interactive}" -eq 1 ]]; then
        local frame="${spinner:spinner_index:1}"
        spinner_index=$(((spinner_index + 1) % 4))
        printf "\r${_tty_bold}${_tty_cyan}[voice]${_tty_reset} %s... [%s] %ss" "${label}" "${frame}" "${elapsed}" >&2
      elif [[ "${elapsed}" -ge "${next_log}" ]]; then
        step "${label} still running... ${elapsed}s elapsed"
        next_log=$((next_log + log_interval))
      fi
    fi
  done

  local exit_code=0
  wait "${cmd_pid}" || exit_code=$?

  if [[ "${interactive}" -eq 1 ]]; then
    printf "\r\033[2K" >&2
  fi

  return "${exit_code}"
}

write_install_state() {
  mkdir -p "${VOICE_CONFIG_DIR}"

  local managed_paths=(
    "${LOCAL_BIN}/voice"
    "${LOCAL_BIN}/whisper-cli"
    "${LOCAL_APPS_DIR}/${VOICE_PORTAL_DESKTOP_ID}"
    "${SYSTEMD_USER_DIR}/${VOICE_SERVICE_NAME}"
    "${VOICE_CONFIG_DIR}/daemon.env"
    "${VOICE_CONFIG_FILE}"
    "${VOICE_INSTALL_STATE_FILE}"
    "${WHISPER_SRC_DIR}"
    "${WHISPER_MODEL_DIR}"
    "${VOICE_SOCKET_PATH}"
    "${VOICE_RUNTIME_DIR}"
  )

  cat > "${VOICE_INSTALL_STATE_FILE}" <<EOF
{
  "version": 1,
  "package_manager": $(json_quote "${PACKAGE_MANAGER}"),
  "distro_label": $(json_quote "${DISTRO_LABEL}"),
  "session_label": $(json_quote "${SESSION_LABEL}"),
  "default_model_key": $(json_quote "${VOICE_INSTALL_MODEL_KEY:-${RECOMMENDED_MODEL_KEY:-small}}"),
  "service_name": $(json_quote "${VOICE_SERVICE_NAME}"),
  "desktop_file": $(json_quote "${LOCAL_APPS_DIR}/${VOICE_PORTAL_DESKTOP_ID}"),
  "managed_paths": $(json_array_from_args "${managed_paths[@]}"),
  "installed_packages": $(json_array_from_args "${INSTALL_PACKAGES[@]}"),
  "removable_packages": $(json_array_from_args "${REMOVABLE_PACKAGE_CANDIDATES[@]}"),
  "retained_packages": $(json_array_from_args "${RETAINED_SHARED_PACKAGES[@]}")
}
EOF

  ok "Install state: ${VOICE_INSTALL_STATE_FILE}"
}

manifest_field() {
  local field="$1"
  python3 - "${VOICE_INSTALL_STATE_FILE}" "${field}" <<'PY'
import json
import sys
from pathlib import Path

manifest = Path(sys.argv[1])
field = sys.argv[2]
if not manifest.is_file():
    sys.exit(1)
data = json.loads(manifest.read_text(encoding="utf-8"))
value = data.get(field)
if value is None:
    sys.exit(1)
if isinstance(value, list):
    for item in value:
        print(item)
else:
    print(value)
PY
}

# ---------------------------------------------------------------------------
# prerequisites and session/package-manager detection
# ---------------------------------------------------------------------------
detect_package_manager() {
  if command -v apt-get &>/dev/null; then
    PACKAGE_MANAGER="apt"
    DISTRO_LABEL="apt-based distro"
    return 0
  fi

  if command -v dnf &>/dev/null; then
    PACKAGE_MANAGER="dnf"
    DISTRO_LABEL="Fedora-like distro"
    return 0
  fi

  if [[ "${RESET}" -eq 1 ]]; then
    warn "Unsupported package manager for package cleanup; artifact reset will still work."
    PACKAGE_MANAGER=""
    DISTRO_LABEL="unknown distro"
    return 0
  fi

  die "Unsupported Linux package manager. Expected apt-get or dnf."
}

detect_session() {
  local session_type="${XDG_SESSION_TYPE:-}"
  if [[ "${session_type,,}" == "wayland" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    SESSION_LABEL="Wayland"
  elif [[ -n "${DISPLAY:-}" ]]; then
    SESSION_LABEL="X11"
  else
    SESSION_LABEL="headless"
  fi
}

check_prerequisites() {
  step "Checking prerequisites..."

  detect_package_manager
  detect_session

  if ! command -v python3 &>/dev/null; then
    die "python3 is required but not found. Install it with your system package manager first."
  fi

  if ! command -v git &>/dev/null; then
    die "git is required but not found. Install it with your system package manager first."
  fi

  ok "Prerequisites OK (${DISTRO_LABEL})"
}

package_installed() {
  local package="$1"
  case "${PACKAGE_MANAGER}" in
    apt)
      dpkg -s "${package}" >/dev/null 2>&1
      ;;
    dnf)
      rpm -q "${package}" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

filter_installed_packages() {
  local package=""
  for package in "$@"; do
    if package_installed "${package}"; then
      printf '%s\n' "${package}"
    fi
  done
}

filter_removable_packages() {
  local package=""
  local removable=()
  for package in "$@"; do
    if ! array_contains "${package}" "${RETAINED_SHARED_PACKAGES[@]}"; then
      removable+=("${package}")
    fi
  done
  printf '%s\n' "${removable[@]}"
}

# ---------------------------------------------------------------------------
# install_apt_packages / install_dnf_packages
# ---------------------------------------------------------------------------
install_optional_apt_packages() {
  local available=()
  local package=""
  for package in "$@"; do
    if apt-cache show "${package}" >/dev/null 2>&1; then
      available+=("${package}")
    else
      warn "Optional package unavailable on this apt repo set: ${package}"
    fi
  done

  if [[ "${#available[@]}" -gt 0 ]]; then
    sudo apt-get install -y -qq --no-upgrade "${available[@]}"
    printf '%s\n' "${available[@]}"
  fi
}

install_apt_packages() {
  step "Installing system packages..."

  sudo apt-get update -qq

  local packages=("${APT_CORE_PACKAGES[@]}")
  local optional_installed=()
  RETAINED_SHARED_PACKAGES=("${APT_RETAINED_PACKAGES[@]}")

  # Audio: if PipeWire/PulseAudio is already running keep it; otherwise add ALSA
  if pactl info &>/dev/null 2>&1; then
    ok "Audio server already running — skipping audio package installation"
  else
    packages+=("${APT_AUDIO_FALLBACK_PACKAGES[@]}")
  fi

  sudo apt-get install -y -qq --no-upgrade "${packages[@]}"
  ok "Core apt packages ready"
  step "Checking optional apt packages (Wayland/Vulkan helpers)..."
  mapfile -t optional_installed < <(install_optional_apt_packages "${APT_OPTIONAL_PACKAGES[@]}")
  if [[ "${#optional_installed[@]}" -gt 0 ]]; then
    ok "Optional apt packages ready: ${optional_installed[*]}"
  else
    ok "No optional apt packages available to install"
  fi

  INSTALL_PACKAGES=("${packages[@]}" "${optional_installed[@]}")
  mapfile -t REMOVABLE_PACKAGE_CANDIDATES < <(filter_removable_packages "${INSTALL_PACKAGES[@]}")

  ok "System packages installed"
}

install_dnf_packages() {
  step "Installing system packages..."

  sudo dnf makecache -q -y

  RETAINED_SHARED_PACKAGES=("${DNF_RETAINED_PACKAGES[@]}")
  INSTALL_PACKAGES=("${DNF_CORE_PACKAGES[@]}")

  sudo dnf install -q -y "${INSTALL_PACKAGES[@]}"
  ok "Core Fedora packages ready"
  step "Installing optional Fedora packages (Wayland/Vulkan helpers; unavailable ones will be skipped)..."
  sudo dnf install -q -y --skip-unavailable "${DNF_OPTIONAL_PACKAGES[@]}" || true
  ok "Optional Fedora package pass complete"
  INSTALL_PACKAGES+=("${DNF_OPTIONAL_PACKAGES[@]}")

  mapfile -t REMOVABLE_PACKAGE_CANDIDATES < <(filter_removable_packages "${INSTALL_PACKAGES[@]}")

  ok "System packages installed"
}

install_system_packages() {
  case "${PACKAGE_MANAGER}" in
    apt) install_apt_packages ;;
    dnf) install_dnf_packages ;;
    *) die "Unsupported package manager: ${PACKAGE_MANAGER}" ;;
  esac
}

# ---------------------------------------------------------------------------
# detect_gpu — sets CMAKE_GPU_FLAGS and GPU_LABEL
# ---------------------------------------------------------------------------
detect_gpu() {
  step "Detecting GPU..."

  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    if command -v nvcc &>/dev/null 2>&1; then
      CMAKE_GPU_FLAGS="-DGGML_CUDA=ON"
      GPU_LABEL="NVIDIA CUDA"
      RECOMMENDED_MODEL_KEY="small"
      ok "GPU: ${GPU_LABEL}"
      return 0
    fi

    if [[ -n "${CUDAToolkit_ROOT:-}" ]] && [[ -d "${CUDAToolkit_ROOT}" ]]; then
      CMAKE_GPU_FLAGS="-DGGML_CUDA=ON"
      GPU_LABEL="NVIDIA CUDA"
      RECOMMENDED_MODEL_KEY="small"
      ok "GPU: ${GPU_LABEL} (via CUDAToolkit_ROOT)"
      return 0
    fi

    warn "NVIDIA GPU detected but CUDA toolkit not found. Falling back to non-CUDA build."
    warn "Install CUDA and set CUDAToolkit_ROOT if you want CUDA acceleration."
  fi

  if vulkan_build_ready; then
    CMAKE_GPU_FLAGS="-DGGML_VULKAN=1"
    GPU_LABEL="Vulkan"
    RECOMMENDED_MODEL_KEY="small"
    ok "GPU: ${GPU_LABEL}"
  else
    if command -v vulkaninfo &>/dev/null && vulkaninfo &>/dev/null 2>&1; then
      warn "Vulkan runtime detected but build prerequisites are incomplete. Falling back to CPU + OpenBLAS."
      warn "Install Vulkan development files and glslc if you want Vulkan acceleration."
    fi
    CMAKE_GPU_FLAGS="-DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS"
    GPU_LABEL="CPU + OpenBLAS"
    RECOMMENDED_MODEL_KEY="small"
    ok "GPU: none detected — using ${GPU_LABEL}"
  fi
}

vulkan_build_ready() {
  if ! command -v vulkaninfo &>/dev/null || ! vulkaninfo &>/dev/null 2>&1; then
    return 1
  fi

  if ! command -v glslc &>/dev/null; then
    return 1
  fi

  cmake --find-package \
    -DNAME=Vulkan \
    -DCOMPILER_ID=GNU \
    -DLANGUAGE=CXX \
    -DMODE=EXIST >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# build_whisper_cpp
# ---------------------------------------------------------------------------
build_whisper_cpp() {
  if [[ -x "${WHISPER_BIN}" ]] && [[ "${UPDATE}" -eq 0 ]]; then
    ok "whisper-cli already built — skipping (pass --update to rebuild)"
    return 0
  fi

  if [[ ! -d "${WHISPER_SRC_DIR}/.git" ]]; then
    step "Cloning whisper.cpp..."
    mkdir -p "$(dirname "${WHISPER_SRC_DIR}")"
    run_with_keepalive "Cloning whisper.cpp" git clone --quiet --depth=1 "${WHISPER_REPO}" "${WHISPER_SRC_DIR}"
  fi

  if [[ "${UPDATE}" -eq 1 ]]; then
    step "Updating whisper.cpp..."
    run_with_keepalive "Updating whisper.cpp" git -C "${WHISPER_SRC_DIR}" pull --quiet --ff-only
  fi

  if [[ -f "${WHISPER_CMAKE_CACHE_FILE}" ]] && [[ "${CMAKE_GPU_FLAGS}" != *"GGML_CUDA=ON"* ]]; then
    if grep -q "GGML_CUDA:.*=ON" "${WHISPER_CMAKE_CACHE_FILE}"; then
      warn "Found stale CUDA config in cached CMake state. Clearing build directory."
      rm -rf "${WHISPER_BUILD_DIR}"
    fi
  fi

  if [[ -f "${WHISPER_BUILD_FLAGS_FILE}" ]]; then
    local previous_flags
    previous_flags="$(<"${WHISPER_BUILD_FLAGS_FILE}")"
    if [[ "${previous_flags}" != "${CMAKE_GPU_FLAGS}" ]]; then
      warn "Build backend changed since last run. Clearing cached CMake build directory."
      rm -rf "${WHISPER_BUILD_DIR}"
    fi
  fi

  step "Configuring whisper.cpp (${GPU_LABEL})..."
  # shellcheck disable=SC2086
  cmake -B "${WHISPER_BUILD_DIR}" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        ${CMAKE_GPU_FLAGS} \
        -S "${WHISPER_SRC_DIR}"

  printf '%s' "${CMAKE_GPU_FLAGS}" > "${WHISPER_BUILD_FLAGS_FILE}"

  step "Building whisper-cli (this takes a few minutes)..."
  run_with_keepalive "Building whisper-cli" \
    cmake --build "${WHISPER_BUILD_DIR}" \
      --target whisper-cli \
      -j "$(nproc)"

  if [[ ! -x "${WHISPER_BIN}" ]]; then
    die "Build succeeded but whisper-cli binary not found at ${WHISPER_BIN}"
  fi

  ok "whisper-cli built at ${WHISPER_BIN}"
}

# ---------------------------------------------------------------------------
# install_symlinks / desktop entry / service
# ---------------------------------------------------------------------------
_install_symlink() {
  local target="$1"
  local link="$2"
  local label="$3"

  if [[ -e "${link}" && ! -L "${link}" ]]; then
    warn "${link} exists as a regular file — not overwriting. Remove it manually if you want the symlink."
    return 0
  fi

  if [[ -L "${link}" ]] && [[ "$(readlink "${link}")" == "${target}" ]]; then
    ok "${label}: symlink already up to date"
    return 0
  fi

  ln -sf "${target}" "${link}"
  ok "${label}: ${link} -> ${target}"
}

install_symlinks() {
  step "Installing symlinks to ~/.local/bin..."

  mkdir -p "${LOCAL_BIN}"
  _install_symlink "${WHISPER_BIN}" "${LOCAL_BIN}/whisper-cli" "whisper-cli"
  _install_symlink "${VOICE_WRAPPER}" "${LOCAL_BIN}/voice" "voice"

  ok "Symlinks installed"
}

install_desktop_entry() {
  step "Installing desktop entry..."

  mkdir -p "${LOCAL_APPS_DIR}"
  install -m 0644 "${VOICE_DESKTOP_FILE}" "${LOCAL_APPS_DIR}/${VOICE_PORTAL_DESKTOP_ID}"

  ok "Desktop entry: ${LOCAL_APPS_DIR}/${VOICE_PORTAL_DESKTOP_ID}"
}

install_user_service() {
  step "Installing systemd user service..."

  mkdir -p "${SYSTEMD_USER_DIR}" "${VOICE_CONFIG_DIR}"
  install -m 0644 "${VOICE_DAEMON_SERVICE_FILE}" "${SYSTEMD_USER_DIR}/${VOICE_SERVICE_NAME}"

  if [[ ! -f "${VOICE_CONFIG_DIR}/daemon.env" ]]; then
    install -m 0644 "${VOICE_DAEMON_ENV_EXAMPLE}" "${VOICE_CONFIG_DIR}/daemon.env"
    ok "Daemon env template: ${VOICE_CONFIG_DIR}/daemon.env"
  else
    ok "Daemon env already exists: ${VOICE_CONFIG_DIR}/daemon.env"
  fi

  ok "User service: ${SYSTEMD_USER_DIR}/${VOICE_SERVICE_NAME}"
}

enable_user_service() {
  if ! command -v systemctl &>/dev/null; then
    warn "systemctl not found; skipping user-service enable."
    warn "Manual step: systemctl --user daemon-reload && systemctl --user enable --now ${VOICE_SERVICE_NAME}"
    return 0
  fi

  if ! systemctl --user daemon-reload &>/dev/null; then
    warn "Could not reach the systemd user manager; service was installed but not enabled."
    warn "Manual step: systemctl --user daemon-reload && systemctl --user enable --now ${VOICE_SERVICE_NAME}"
    return 0
  fi

  step "Enabling systemd user service..."
  systemctl --user enable --now "${VOICE_SERVICE_NAME}"
  systemctl --user restart "${VOICE_SERVICE_NAME}"
  ok "User service enabled: ${VOICE_SERVICE_NAME}"
}

install_default_model() {
  local model_key="${VOICE_INSTALL_MODEL_KEY:-${RECOMMENDED_MODEL_KEY:-small}}"
  step "Installing default Whisper model (${model_key})..."

  if command -v voice &>/dev/null; then
    voice model-install --key "${model_key}" --activate --if-missing
  elif [[ -x "${LOCAL_BIN}/voice" ]]; then
    "${LOCAL_BIN}/voice" model-install --key "${model_key}" --activate --if-missing
  else
    python3 "${REPO_ROOT}/tools/voice-cli/voice.py" model-install --key "${model_key}" --activate --if-missing
  fi

  ok "Default Whisper model ready (${model_key})"
}

# ---------------------------------------------------------------------------
# ensure_path / doctor
# ---------------------------------------------------------------------------
ensure_path() {
  if [[ ":${PATH}:" == *":${LOCAL_BIN}:"* ]]; then
    ok "~/.local/bin already in PATH"
    return 0
  fi

  step "Adding ~/.local/bin to PATH..."

  local path_line='export PATH="$HOME/.local/bin:$PATH"'
  local added=0
  local rc=""

  for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    if [[ -f "${rc}" ]]; then
      if ! grep -qF '.local/bin' "${rc}"; then
        printf '\n# Added by voice install\n%s\n' "${path_line}" >> "${rc}"
        ok "Added to ${rc}"
        added=1
      else
        ok "${rc} already references .local/bin"
      fi
    fi
  done

  if [[ "${added}" -eq 1 ]]; then
    warn "PATH updated in shell config but not active in this session."
    warn "To activate now:  export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
}

run_doctor() {
  step "Running voice doctor..."

  if command -v voice &>/dev/null; then
    voice doctor
  elif [[ -x "${LOCAL_BIN}/voice" ]]; then
    "${LOCAL_BIN}/voice" doctor
  else
    python3 "${REPO_ROOT}/tools/voice-cli/voice.py" doctor
  fi
}

# ---------------------------------------------------------------------------
# reset planning helpers
# ---------------------------------------------------------------------------
load_reset_plan_from_manifest() {
  local field=""

  if [[ ! -f "${VOICE_INSTALL_STATE_FILE}" ]]; then
    return 1
  fi

  if ! manifest_field "managed_paths" >/dev/null 2>&1; then
    return 1
  fi

  RESET_PLAN_SOURCE="manifest"

  while IFS= read -r field; do
    [[ -n "${field}" ]] && append_unique RESET_MANAGED_PATHS "${field}"
  done < <(manifest_field "managed_paths")

  if manifest_field "removable_packages" >/dev/null 2>&1; then
    while IFS= read -r field; do
      [[ -n "${field}" ]] && append_unique RESET_PACKAGE_CANDIDATES "${field}"
    done < <(manifest_field "removable_packages")
  fi

  if manifest_field "retained_packages" >/dev/null 2>&1; then
    while IFS= read -r field; do
      [[ -n "${field}" ]] && append_unique RESET_RETAINED_PACKAGES "${field}"
    done < <(manifest_field "retained_packages")
  fi

  if manifest_field "package_manager" >/dev/null 2>&1; then
    PACKAGE_MANAGER="$(manifest_field "package_manager" | head -n 1)"
  fi

  return 0
}

collect_heuristic_reset_paths() {
  local default_paths=(
    "${LOCAL_BIN}/voice"
    "${LOCAL_BIN}/whisper-cli"
    "${LOCAL_APPS_DIR}/${VOICE_PORTAL_DESKTOP_ID}"
    "${SYSTEMD_USER_DIR}/${VOICE_SERVICE_NAME}"
    "${VOICE_CONFIG_DIR}/daemon.env"
    "${VOICE_CONFIG_FILE}"
    "${VOICE_INSTALL_STATE_FILE}"
    "${WHISPER_SRC_DIR}"
    "${WHISPER_MODEL_DIR}"
    "${VOICE_SOCKET_PATH}"
    "${VOICE_RUNTIME_DIR}"
  )
  local item=""
  for item in "${default_paths[@]}"; do
    append_unique RESET_MANAGED_PATHS "${item}"
  done
}

collect_heuristic_package_candidates() {
  if [[ -z "${PACKAGE_MANAGER}" ]]; then
    return 0
  fi

  case "${PACKAGE_MANAGER}" in
    apt)
      RETAINED_SHARED_PACKAGES=("${APT_RETAINED_PACKAGES[@]}")
      RESET_RETAINED_PACKAGES=("${APT_RETAINED_PACKAGES[@]}")
      mapfile -t RESET_PACKAGE_CANDIDATES < <(filter_removable_packages "${APT_CORE_PACKAGES[@]}" "${APT_AUDIO_FALLBACK_PACKAGES[@]}" "${APT_OPTIONAL_PACKAGES[@]}")
      ;;
    dnf)
      RETAINED_SHARED_PACKAGES=("${DNF_RETAINED_PACKAGES[@]}")
      RESET_RETAINED_PACKAGES=("${DNF_RETAINED_PACKAGES[@]}")
      mapfile -t RESET_PACKAGE_CANDIDATES < <(filter_removable_packages "${DNF_CORE_PACKAGES[@]}" "${DNF_OPTIONAL_PACKAGES[@]}")
      ;;
  esac
}

collect_reset_plan() {
  RESET_PLAN_SOURCE="heuristic"
  RESET_MANAGED_PATHS=()
  RESET_ARTIFACTS=()
  RESET_PRUNE_DIRS=()
  RESET_PACKAGE_CANDIDATES=()
  RESET_RETAINED_PACKAGES=()
  RESET_SERVICE_ACTIONS=(
    "Stop ${VOICE_SERVICE_NAME} if running"
    "Disable ${VOICE_SERVICE_NAME} if enabled"
    "Reload the systemd user manager after removing the unit"
  )

  detect_session
  detect_package_manager
  load_reset_plan_from_manifest || true
  collect_heuristic_reset_paths

  if [[ "${#RESET_PACKAGE_CANDIDATES[@]}" -eq 0 ]]; then
    collect_heuristic_package_candidates
  fi

  local item=""
  for item in "${RESET_MANAGED_PATHS[@]}"; do
    case "${item}" in
      "${VOICE_RUNTIME_DIR}")
        append_unique RESET_PRUNE_DIRS "${VOICE_RUNTIME_DIR}"
        ;;
      "${VOICE_SOCKET_PATH}")
        append_unique RESET_ARTIFACTS "${VOICE_SOCKET_PATH}"
        ;;
      "${WHISPER_MODEL_DIR}")
        append_unique RESET_ARTIFACTS "${WHISPER_MODEL_DIR}"
        append_unique RESET_PRUNE_DIRS "${VOICE_MODEL_ROOT}"
        append_unique RESET_PRUNE_DIRS "${VOICE_DATA_DIR}"
        ;;
      "${WHISPER_SRC_DIR}")
        append_unique RESET_ARTIFACTS "${WHISPER_SRC_DIR}"
        append_unique RESET_PRUNE_DIRS "${WHISPER_SRC_PARENT_DIR}"
        append_unique RESET_PRUNE_DIRS "${VOICE_DATA_DIR}"
        ;;
      "${VOICE_CONFIG_DIR}/daemon.env"|\
      "${VOICE_CONFIG_FILE}"|\
      "${VOICE_INSTALL_STATE_FILE}")
        append_unique RESET_ARTIFACTS "${item}"
        append_unique RESET_PRUNE_DIRS "${VOICE_CONFIG_DIR}"
        ;;
      *)
        append_unique RESET_ARTIFACTS "${item}"
        ;;
    esac
  done

  if [[ "${REMOVE_PACKAGES}" -eq 1 && -n "${PACKAGE_MANAGER}" ]]; then
    mapfile -t RESET_PACKAGE_CANDIDATES < <(filter_installed_packages "${RESET_PACKAGE_CANDIDATES[@]}")
  fi
}

print_reset_summary() {
  echo ""
  step "Reset plan (${RESET_PLAN_SOURCE})"
  echo ""
  echo "This will remove Voice-managed artifacts so you can simulate a fresh install."
  echo ""
  echo "Service actions:"
  print_list "${RESET_SERVICE_ACTIONS[@]}"
  echo ""
  echo "Artifacts to remove:"
  if [[ "${#RESET_ARTIFACTS[@]}" -gt 0 ]]; then
    print_list "${RESET_ARTIFACTS[@]}"
  else
    echo "  - none"
  fi
  echo ""
  echo "Directories to prune if empty:"
  if [[ "${#RESET_PRUNE_DIRS[@]}" -gt 0 ]]; then
    print_list "${RESET_PRUNE_DIRS[@]}"
  else
    echo "  - none"
  fi

  if [[ "${REMOVE_PACKAGES}" -eq 1 ]]; then
    echo ""
    echo "Package cleanup candidates (${PACKAGE_MANAGER:-unavailable}):"
    if [[ "${#RESET_PACKAGE_CANDIDATES[@]}" -gt 0 ]]; then
      print_list "${RESET_PACKAGE_CANDIDATES[@]}"
    else
      echo "  - none"
    fi
    echo ""
    echo "Shared prerequisites retained:"
    if [[ "${#RESET_RETAINED_PACKAGES[@]}" -gt 0 ]]; then
      print_list "${RESET_RETAINED_PACKAGES[@]}"
    else
      echo "  - none"
    fi
  fi
  echo ""
}

confirm_reset_plan() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 1
  fi

  if [[ "${ASSUME_YES}" -eq 1 ]]; then
    return 0
  fi

  local answer=""
  read -r -p "Proceed with reset? [y/N] " answer
  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# reset execution helpers
# ---------------------------------------------------------------------------
remove_symlink_if_managed() {
  local path="$1"
  local expected_target="$2"

  if [[ -L "${path}" ]]; then
    if [[ -z "${expected_target}" || "$(readlink "${path}")" == "${expected_target}" ]]; then
      rm -f "${path}"
      ok "Removed ${path}"
    else
      warn "Skipping ${path}: symlink target no longer matches installer-managed target."
    fi
  elif [[ -e "${path}" ]]; then
    warn "Skipping ${path}: exists as a regular file, not an installer-managed symlink."
  fi
}

remove_path_if_present() {
  local path="$1"
  if [[ -e "${path}" || -L "${path}" ]]; then
    rm -rf "${path}"
    ok "Removed ${path}"
  fi
}

prune_dir_if_empty() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    rmdir "${path}" 2>/dev/null || true
  fi
}

stop_user_service_for_reset() {
  if ! command -v systemctl &>/dev/null; then
    warn "systemctl not found; skipping user-service stop/disable."
    return 0
  fi

  if ! systemctl --user daemon-reload &>/dev/null; then
    warn "Could not reach the systemd user manager; continuing with file cleanup."
    return 0
  fi

  systemctl --user disable --now "${VOICE_SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl --user reset-failed "${VOICE_SERVICE_NAME}" >/dev/null 2>&1 || true
  ok "User service stopped/disabled when present"
}

reload_user_manager_after_reset() {
  if command -v systemctl &>/dev/null; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
}

remove_voice_artifacts() {
  remove_symlink_if_managed "${LOCAL_BIN}/voice" "${VOICE_WRAPPER}"
  remove_symlink_if_managed "${LOCAL_BIN}/whisper-cli" "${WHISPER_BIN}"

  local path=""
  for path in "${RESET_ARTIFACTS[@]}"; do
    case "${path}" in
      "${LOCAL_BIN}/voice"|\
      "${LOCAL_BIN}/whisper-cli")
        ;;
      *)
        remove_path_if_present "${path}"
        ;;
    esac
  done

  for path in "${RESET_PRUNE_DIRS[@]}"; do
    prune_dir_if_empty "${path}"
  done

  ok "Voice-managed artifacts removed"
}

remove_system_packages() {
  if [[ "${REMOVE_PACKAGES}" -eq 0 ]]; then
    return 0
  fi

  if [[ "${#RESET_PACKAGE_CANDIDATES[@]}" -eq 0 ]]; then
    ok "No installer-known packages to remove"
    return 0
  fi

  step "Removing installer-known packages..."
  case "${PACKAGE_MANAGER}" in
    apt)
      sudo apt-get remove -y "${RESET_PACKAGE_CANDIDATES[@]}"
      sudo apt-get autoremove -y
      ;;
    dnf)
      sudo dnf remove -y "${RESET_PACKAGE_CANDIDATES[@]}"
      ;;
    *)
      warn "Package cleanup unavailable on this distro; skipping."
      return 0
      ;;
  esac
  ok "Package cleanup complete"
}

run_reset() {
  echo ""
  step "Voice Linux reset"

  collect_reset_plan
  print_reset_summary

  if ! confirm_reset_plan; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      ok "Dry run complete."
      return 0
    fi
    warn "Reset cancelled."
    return 0
  fi

  stop_user_service_for_reset
  remove_voice_artifacts
  reload_user_manager_after_reset
  remove_system_packages

  echo ""
  ok "Reset complete."
  echo ""
  echo "  Reinstall:      bash tools/voice-cli/install.sh"
  echo "  Dry-run reset:  bash tools/voice-cli/install.sh --reset --dry-run"
  if [[ "${REMOVE_PACKAGES}" -eq 0 ]]; then
    echo "  Full uninstall: bash tools/voice-cli/install.sh --reset --remove-packages"
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  if [[ "${RESET}" -eq 1 ]]; then
    run_reset
    return 0
  fi

  echo ""
  step "Voice Linux setup"
  echo ""

  check_prerequisites
  install_system_packages
  detect_gpu
  build_whisper_cpp
  install_symlinks
  install_desktop_entry
  install_user_service
  install_default_model
  ensure_path
  enable_user_service
  write_install_state
  run_doctor

  echo ""
  ok "Setup complete."
  echo ""
  echo "  Session type:     ${SESSION_LABEL}"
  echo "  Default model:    ${VOICE_INSTALL_MODEL_KEY:-${RECOMMENDED_MODEL_KEY:-small}}"
  echo "  Launch the TUI:   voice"
  echo "  Service status:   systemctl --user status ${VOICE_SERVICE_NAME}"
  echo "  Reset install:    bash tools/voice-cli/install.sh --reset --dry-run"
  echo "  Change model:     press M inside the TUI"
  echo "  Start recording:  press R"
  echo ""
}

main
