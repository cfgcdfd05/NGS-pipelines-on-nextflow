#!/usr/bin/env bash
# ==============================================================================
# Nextflow Genomics Suite - Fix Linux Qt6 / PySide6 XCB Platform Dependencies
# ==============================================================================
# This script automatically installs libxcb-cursor0 / xcb-util-cursor and other
# required Qt6 XCB platform libraries on Linux distributions to resolve:
#   "qt.qpa.plugin: from 6.50, xcb-cursor0 or libxcb-curosr0 is needed to load the Qt xcb platform plugin"
#   "qt.qpa.plugin: Could not load the Qt platform plugin 'xcb' in '' even though it was found."
# ==============================================================================

set -euo pipefail

echo "========================================================================"
echo " Nextflow Genomics Suite - Qt6 / PySide6 Linux GUI Dependency Fixer"
echo "========================================================================"
echo ""

# Detect Operating System
OS_TYPE="$(uname -s)"
if [[ "$OS_TYPE" != "Linux" ]]; then
    echo "This script is intended for Linux systems. Current OS: $OS_TYPE"
    exit 0
fi

# Detect package manager and install required XCB libraries
if command -v apt-get >/dev/null 2>&1; then
    echo "Detected Debian/Ubuntu/Mint package manager (apt-get)."
    echo "Installing required Qt6 XCB platform libraries including libxcb-cursor0..."
    echo ""
    sudo apt-get update
    sudo apt-get install -y \
        libxcb-cursor0 \
        libxcb-glx0 \
        libxcb-icccm4 \
        libxcb-image0 \
        libxcb-keysyms1 \
        libxcb-randr0 \
        libxcb-render-util0 \
        libxcb-shape0 \
        libxcb-shm0 \
        libxcb-sync1 \
        libxcb-xfixes0 \
        libxcb-xinerama0 \
        libxcb-xkb1 \
        libxkbcommon-x11-0 \
        libx11-xcb1 \
        libgl1 \
        libegl1 \
        libdbus-1-3 \
        libfontconfig1
    echo ""
    echo "SUCCESS: Debian/Ubuntu XCB platform libraries installed successfully."

elif command -v dnf >/dev/null 2>&1; then
    echo "Detected Fedora/RHEL/Rocky/AlmaLinux package manager (dnf)."
    echo "Installing required Qt6 XCB platform libraries including xcb-util-cursor..."
    echo ""
    sudo dnf install -y \
        xcb-util-cursor \
        xcb-util-wm \
        xcb-util-keysyms \
        xcb-util-image \
        xcb-util-renderutil \
        libxkbcommon-x11 \
        mesa-libGL \
        mesa-libEGL \
        dbus-libs \
        fontconfig
    echo ""
    echo "SUCCESS: RHEL/Fedora XCB platform libraries installed successfully."

elif command -v yum >/dev/null 2>&1; then
    echo "Detected CentOS/RHEL package manager (yum)."
    echo "Installing required Qt6 XCB platform libraries including xcb-util-cursor..."
    echo ""
    sudo yum install -y \
        xcb-util-cursor \
        xcb-util-wm \
        xcb-util-keysyms \
        xcb-util-image \
        xcb-util-renderutil \
        libxkbcommon-x11
    echo ""
    echo "SUCCESS: RHEL/CentOS XCB platform libraries installed successfully."

elif command -v pacman >/dev/null 2>&1; then
    echo "Detected Arch Linux/Manjaro package manager (pacman)."
    echo "Installing required Qt6 XCB platform libraries including xcb-util-cursor..."
    echo ""
    sudo pacman -S --needed --noconfirm \
        xcb-util-cursor \
        xcb-util-wm \
        xcb-util-keysyms \
        xcb-util-image \
        xcb-util-renderutil \
        libxkbcommon-x11 \
        mesa \
        dbus \
        fontconfig
    echo ""
    echo "SUCCESS: Arch Linux XCB platform libraries installed successfully."

elif command -v zypper >/dev/null 2>&1; then
    echo "Detected openSUSE/SLES package manager (zypper)."
    echo "Installing required Qt6 XCB platform libraries..."
    echo ""
    sudo zypper install -y \
        libxcb-cursor0 \
        libxcb-glx0 \
        libxcb-icccm4 \
        libxcb-image0 \
        libxcb-keysyms1 \
        libxcb-render-util0 \
        libxkbcommon-x11-0
    echo ""
    echo "SUCCESS: openSUSE XCB platform libraries installed successfully."

else
    echo "ERROR: Unsupported Linux package manager."
    echo "Please install 'libxcb-cursor0' (or 'xcb-util-cursor') using your system package manager."
    exit 1
fi

echo ""
echo "========================================================================"
echo " All Qt6 / PySide6 Linux GUI dependencies have been fixed!"
echo " You can now launch the application by running: ./start_gui.sh"
echo "========================================================================"
