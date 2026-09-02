#!/usr/bin/env bash
# Swarm installer for Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/SwayamDani/swarm-releases/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --gui
#   curl -fsSL .../install.sh | bash -s -- --system
#
# Default behaviour (no flags) mirrors rustup/Homebrew/Ollama: silent, no
# prompts, auto-detects the GPU and installs per-user (no root needed).
# --gui drives the same steps through zenity dialogs instead of plain stdout.
# --system installs to /opt/swarm + /usr/share/applications (needs a
# permission prompt: sudo normally, pkexec under --gui).
#
# This script uses bash-only syntax ([[, arrays). Piping into `sh` instead
# of `bash` runs it under dash on Debian/Ubuntu, which silently treats every
# `[[ ]]` as a failed command (exit 127) rather than erroring — so every
# conditional branch resolves to false and the installer corrupts silently
# (e.g. picks the single-file download path for the GPU build, which only
# ships as split parts, and 404s). This guard fails loudly instead.
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERROR: this installer requires bash, not sh. Re-run with:" >&2
    echo "  curl -fsSL https://raw.githubusercontent.com/SwayamDani/swarm-releases/main/install.sh | bash" >&2
    exit 1
fi

set -euo pipefail

APP_VERSION="0.1.0-beta.1"
RELEASES_REPO="SwayamDani/swarm-releases"
RELEASE_TAG="app-v${APP_VERSION}"
RELEASE_URL="https://github.com/${RELEASES_REPO}/releases/download/${RELEASE_TAG}"

GUI=0
SCOPE="user"

for arg in "$@"; do
    case "$arg" in
        --gui) GUI=1 ;;
        --system) SCOPE="system" ;;
        --user) SCOPE="user" ;;
        -h|--help)
            echo "Usage: install.sh [--gui] [--system|--user]"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

log() {
    if [[ "$GUI" -eq 1 ]]; then
        return 0
    fi
    echo "$@"
}

die() {
    if [[ "$GUI" -eq 1 ]] && command -v zenity >/dev/null 2>&1; then
        zenity --error --title "Swarm Installer" --text "$1" 2>/dev/null || true
    else
        echo "ERROR: $1" >&2
    fi
    exit 1
}

if [[ "$(uname -s)" != "Linux" ]]; then
    die "This installer is for Linux only."
fi

if [[ "$GUI" -eq 1 ]] && ! command -v zenity >/dev/null 2>&1; then
    echo "ERROR: --gui requires zenity, which isn't installed (sudo apt install zenity)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# GPU vendor detection
# ---------------------------------------------------------------------------

detect_gpu_vendor() {
    local pci_vga=""
    if command -v lspci >/dev/null 2>&1; then
        pci_vga="$(lspci 2>/dev/null | grep -iE 'vga|3d controller' || true)"
    fi

    if echo "$pci_vga" | grep -qi nvidia; then
        echo "nvidia"
    elif command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        echo "nvidia"
    elif echo "$pci_vga" | grep -qi amd; then
        echo "amd"
    elif echo "$pci_vga" | grep -qi 'intel' && echo "$pci_vga" | grep -qiE 'arc|dg1|dg2'; then
        echo "intel-discrete"
    else
        echo "none"
    fi
}

GPU_VENDOR="$(detect_gpu_vendor)"

# ---------------------------------------------------------------------------
# Variant + scope selection
# ---------------------------------------------------------------------------

VARIANT="cpu"

if [[ "$GUI" -eq 1 ]]; then
    zenity --info --title "Swarm Installer" \
        --text "Welcome to the Swarm installer.\n\nThis will download and install the Swarm app and its local aligner component." \
        2>/dev/null || die "Cancelled."

    case "$GPU_VENDOR" in
        nvidia)
            CHOICE="$(zenity --list --title "Swarm Installer" --text "An NVIDIA GPU was detected. Which build would you like?" \
                --radiolist --column "" --column "Option" \
                TRUE "GPU (CUDA) build — recommended" \
                FALSE "CPU-only build" \
                2>/dev/null)" || die "Cancelled."
            case "$CHOICE" in
                "GPU (CUDA) build — recommended") VARIANT="gpu" ;;
                *) VARIANT="cpu" ;;
            esac
            ;;
        amd|intel-discrete)
            zenity --info --title "Swarm Installer" \
                --text "An AMD/Intel GPU was detected. CUDA acceleration isn't available for this GPU yet — installing the CPU build." \
                2>/dev/null || true
            VARIANT="cpu"
            ;;
        *)
            zenity --info --title "Swarm Installer" \
                --text "No GPU detected — installing the CPU build." \
                2>/dev/null || true
            VARIANT="cpu"
            ;;
    esac

    SCOPE_CHOICE="$(zenity --list --title "Swarm Installer" --text "Where should Swarm be installed?" \
        --radiolist --column "" --column "Option" \
        TRUE "Just for me (no password needed)" \
        FALSE "All users on this computer (requires permission)" \
        2>/dev/null)" || die "Cancelled."
    case "$SCOPE_CHOICE" in
        "All users on this computer (requires permission)") SCOPE="system" ;;
        *) SCOPE="user" ;;
    esac
else
    case "$GPU_VENDOR" in
        nvidia)
            VARIANT="gpu"
            log "NVIDIA GPU detected — installing the GPU (CUDA) build."
            ;;
        amd|intel-discrete)
            log "AMD/Intel GPU detected — CUDA acceleration isn't available for this GPU yet, installing the CPU build."
            ;;
        *)
            log "No GPU detected — installing the CPU build."
            ;;
    esac
fi

log "Variant: $VARIANT, scope: $SCOPE"

# ---------------------------------------------------------------------------
# Download helpers
# ---------------------------------------------------------------------------

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

download() {
    local url="$1"
    local dest="$2"
    local label="$3"

    if [[ "$GUI" -eq 1 ]]; then
        (
            curl -fsSL -o "$dest" "$url" &
            local pid=$!
            local expected
            expected="$(curl -fsSLI "$url" 2>/dev/null | tr -d '\r' | grep -i '^content-length:' | tail -1 | awk '{print $2}')"
            while kill -0 "$pid" 2>/dev/null; do
                if [[ -n "${expected:-}" && "$expected" -gt 0 && -f "$dest" ]]; then
                    local size
                    size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
                    echo $(( size * 100 / expected ))
                fi
                sleep 0.3
            done
            wait "$pid"
        ) | zenity --progress --title "Swarm Installer" --text "Downloading $label…" --auto-close --no-cancel 2>/dev/null \
            || die "Download failed: $label"
    else
        log "Downloading $label…"
        curl -fL --progress-bar -o "$dest" "$url" || die "Download failed: $label"
    fi
}

verify_sha256() {
    local file="$1"
    local expected_file="$2"
    local expected
    expected="$(tr -d ' \n' < "$expected_file")"
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "$expected" != "$actual" ]]; then
        die "Checksum mismatch for $(basename "$file") — download may be corrupt."
    fi
}

TRIPLE="x86_64-unknown-linux-gnu"
ALIGNER_ASSET="aligner-${VARIANT}-${TRIPLE}"
APP_ASSET="Swarm-${APP_VERSION}-${TRIPLE}.AppImage"

download "${RELEASE_URL}/${ALIGNER_ASSET}.sha256" "${TMP_DIR}/${ALIGNER_ASSET}.sha256" "aligner checksum"
if [[ "$VARIANT" == "gpu" ]]; then
    # gpu's raw binary (~2.6GB, bundled CUDA/cuDNN libs) is over GitHub
    # Releases' 2GB-per-asset hard limit — gzip barely helps (already-dense
    # compiled code/math-library binaries don't compress), so it ships
    # split into <2GB parts instead and gets reassembled here. cpu (~555MB)
    # never needs this, hence the branch rather than always multi-part.
    : > "${TMP_DIR}/${ALIGNER_ASSET}"
    part_num=0
    while :; do
        part_name="${ALIGNER_ASSET}.part$(printf '%02d' "$part_num")"
        part_url="${RELEASE_URL}/${part_name}"
        if ! curl -fsSLI "$part_url" >/dev/null 2>&1; then
            break
        fi
        download "$part_url" "${TMP_DIR}/${part_name}" "aligner part $((part_num + 1))"
        cat "${TMP_DIR}/${part_name}" >> "${TMP_DIR}/${ALIGNER_ASSET}"
        rm -f "${TMP_DIR}/${part_name}"
        part_num=$((part_num + 1))
    done
    [[ "$part_num" -gt 0 ]] || die "No aligner parts found at ${RELEASE_URL}"
else
    download "${RELEASE_URL}/${ALIGNER_ASSET}" "${TMP_DIR}/${ALIGNER_ASSET}" "aligner (${VARIANT})"
fi
verify_sha256 "${TMP_DIR}/${ALIGNER_ASSET}" "${TMP_DIR}/${ALIGNER_ASSET}.sha256"

download "${RELEASE_URL}/${APP_ASSET}.sha256" "${TMP_DIR}/${APP_ASSET}.sha256" "app checksum"
download "${RELEASE_URL}/${APP_ASSET}" "${TMP_DIR}/${APP_ASSET}" "Swarm app"
verify_sha256 "${TMP_DIR}/${APP_ASSET}" "${TMP_DIR}/${APP_ASSET}.sha256"

# Pre-exported embedding model (ONNX), shared by both cpu and gpu builds —
# the exported graph itself doesn't depend on the execution provider, only
# which provider loads it at runtime. Without this, the aligner's first-ever
# startup pays a one-time ~30-60s PyTorch→ONNX export before it can serve a
# single query. Fetching it here means that cost lands during `install.sh`
# instead of during the user's first launch of the app.
EMBED_CACHE_ASSET="embedding-cache-onnx.tar.gz"
download "${RELEASE_URL}/${EMBED_CACHE_ASSET}.sha256" "${TMP_DIR}/${EMBED_CACHE_ASSET}.sha256" "embedding cache checksum"
download "${RELEASE_URL}/${EMBED_CACHE_ASSET}" "${TMP_DIR}/${EMBED_CACHE_ASSET}" "embedding model cache"
verify_sha256 "${TMP_DIR}/${EMBED_CACHE_ASSET}" "${TMP_DIR}/${EMBED_CACHE_ASSET}.sha256"

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

install_files() {
    local aligner_dir="$1"
    local app_dir="$2"
    local desktop_dir="$3"
    local as_root="$4"

    local maybe_sudo=()
    if [[ "$as_root" -eq 1 ]]; then
        if [[ "$GUI" -eq 1 ]]; then
            maybe_sudo=(pkexec)
        else
            maybe_sudo=(sudo)
        fi
    fi

    "${maybe_sudo[@]}" mkdir -p "$aligner_dir" "$app_dir" "$desktop_dir"
    "${maybe_sudo[@]}" cp "${TMP_DIR}/${ALIGNER_ASSET}" "${aligner_dir}/aligner"
    "${maybe_sudo[@]}" chmod +x "${aligner_dir}/aligner"
    "${maybe_sudo[@]}" cp "${TMP_DIR}/${APP_ASSET}" "${app_dir}/Swarm.AppImage"
    "${maybe_sudo[@]}" chmod +x "${app_dir}/Swarm.AppImage"

    # Launch wrapper, not a direct Exec= to the AppImage: native-Wayland GTK
    # clients on the NVIDIA proprietary driver have long-documented
    # input/focus/stacking bugs (webkit2gtk's DMA-BUF content renderer
    # desyncs input from the visible surface; separately, Mutter's window
    # stacking can misbehave for undecorated GTK windows on the same
    # driver, dropping focus back to the previous window on click).
    # Mesa (AMD/Intel) and X11 sessions aren't affected by either. Detecting
    # this narrow combination at launch time — rather than changing behavior
    # for every install regardless of GPU — keeps native Wayland and
    # hardware acceleration intact for everyone the bugs don't apply to.
    cat > "${TMP_DIR}/swarm-launch.sh" <<'LAUNCHEOF'
#!/usr/bin/env bash
if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] && command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    export WEBKIT_DISABLE_DMABUF_RENDERER=1
    # Route the whole app through XWayland instead of native Wayland: GTK's
    # native-Wayland focus/stacking handling under the NVIDIA driver is
    # markedly less reliable than XWayland's, which is compositor-managed.
    export GDK_BACKEND=x11
fi
exec "$(dirname "$(readlink -f "$0")")/Swarm.AppImage" "$@"
LAUNCHEOF
    "${maybe_sudo[@]}" cp "${TMP_DIR}/swarm-launch.sh" "${app_dir}/swarm-launch.sh"
    "${maybe_sudo[@]}" chmod +x "${app_dir}/swarm-launch.sh"

    cat > "${TMP_DIR}/swarm.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Swarm
Exec=${app_dir}/swarm-launch.sh
Terminal=false
Categories=Utility;
EOF
    "${maybe_sudo[@]}" cp "${TMP_DIR}/swarm.desktop" "${desktop_dir}/swarm.desktop"
}

if [[ "$SCOPE" == "system" ]]; then
    install_files "/opt/swarm/bin" "/opt/swarm" "/usr/share/applications" 1
    APP_PATH="/opt/swarm/swarm-launch.sh"
else
    install_files "${HOME}/.swarm/bin" "${HOME}/.local/share/swarm" "${HOME}/.local/share/applications" 0
    APP_PATH="${HOME}/.local/share/swarm/swarm-launch.sh"
fi

# The aligner always reads/writes its data under the invoking user's own
# HOME (see aligner's config.py `_swarm()` helper) regardless of --system
# vs --user scope — it's never run as root even when the binaries are
# installed to /opt. So the embedding cache always lands here too.
EMBED_CACHE_DIR="${HOME}/.swarm/aligner/.models/onnx-export"
mkdir -p "$EMBED_CACHE_DIR"
tar -xzf "${TMP_DIR}/${EMBED_CACHE_ASSET}" -C "$EMBED_CACHE_DIR"

log "Installed. Aligner (${VARIANT}) and Swarm app are ready."
log "You can now delete this installer — the app and aligner are installed separately."

if [[ "$GUI" -eq 1 ]]; then
    if zenity --question --title "Swarm Installer" --text "Installation complete. Launch Swarm now?" 2>/dev/null; then
        nohup "$APP_PATH" >/dev/null 2>&1 &
    fi
else
    log "Run: $APP_PATH"
fi
