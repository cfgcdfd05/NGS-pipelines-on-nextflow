#!/usr/bin/env bash
set -e

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Starting Nextflow Genomics Suite GUI..."

# Check if the virtual environment exists
if [ ! -d "$PROJECT/.venv" ]; then
    echo "Error: Virtual environment not found."
    echo "Please run ./install.sh first to set up the application."
    exit 1
fi

# Activate the virtual environment
source "$PROJECT/.venv/bin/activate"

# Launch the GUI with diagnostic fallback for missing Linux XCB libraries
if ! python "$PROJECT/interface/gui.py"; then
    echo ""
    echo "=============================================================================="
    echo "GUI LAUNCH FAILED: Missing Linux Qt6 / XCB platform library (libxcb-cursor0)"
    echo "=============================================================================="
    echo "To automatically fix this on your system, run our automated fix script:"
    echo ""
    echo "  ./fix_linux_gui.sh"
    echo ""
    echo "Or install manually for your distribution:"
    echo "  Debian/Ubuntu/Mint : sudo apt-get update && sudo apt-get install -y libxcb-cursor0"
    echo "  Fedora/RHEL/Rocky  : sudo dnf install -y xcb-util-cursor"
    echo "  Arch/Manjaro       : sudo pacman -S --needed xcb-util-cursor"
    echo "=============================================================================="
    deactivate
    exit 1
fi

# Deactivate when closed
deactivate
