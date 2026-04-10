#!/bin/sh
# swap-alert installer
#
# Builds swap-alert from source, installs it to ~/.local/bin, and registers
# a LaunchAgent so it starts automatically at login.
#
# Usage:
#   ./install.sh                                  # from a checkout
#   curl -fsSL <raw-url>/install.sh | sh         # one-liner

set -eu

REPO_URL="https://raw.githubusercontent.com/dpeckham/swap-alert/main"
BIN_DIR="${HOME}/.local/bin"
BIN_PATH="${BIN_DIR}/swap-alert"
LABEL="com.dpeckham.swap-alert"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "swap-alert only runs on macOS." >&2
    exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc not found. Install the Xcode command line tools:" >&2
    echo "    xcode-select --install" >&2
    exit 1
fi

# Work in a temp dir if main.swift isn't next to this script (curl|sh path).
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "")"
if [ -n "${SCRIPT_DIR}" ] && [ -f "${SCRIPT_DIR}/main.swift" ]; then
    SRC_DIR="${SCRIPT_DIR}"
    CLEANUP=""
else
    SRC_DIR="$(mktemp -d)"
    CLEANUP="${SRC_DIR}"
    echo "==> Fetching main.swift"
    curl -fsSL "${REPO_URL}/main.swift" -o "${SRC_DIR}/main.swift"
fi
trap '[ -n "${CLEANUP}" ] && rm -rf "${CLEANUP}"' EXIT INT TERM

echo "==> Building swap-alert"
swiftc -O "${SRC_DIR}/main.swift" -o "${SRC_DIR}/swap-alert" -framework Cocoa

echo "==> Installing to ${BIN_PATH}"
mkdir -p "${BIN_DIR}"
# If a previous instance is running, unload it first so we can overwrite the binary.
if [ -f "${PLIST_PATH}" ]; then
    launchctl unload "${PLIST_PATH}" 2>/dev/null || true
fi
install -m 0755 "${SRC_DIR}/swap-alert" "${BIN_PATH}"

echo "==> Writing LaunchAgent ${PLIST_PATH}"
mkdir -p "${HOME}/Library/LaunchAgents"
cat > "${PLIST_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Loading LaunchAgent"
launchctl load "${PLIST_PATH}"

echo
echo "swap-alert is installed and running. Look for the dot in your menu bar."
echo "To uninstall:"
echo "    launchctl unload ${PLIST_PATH}"
echo "    rm ${PLIST_PATH} ${BIN_PATH}"
