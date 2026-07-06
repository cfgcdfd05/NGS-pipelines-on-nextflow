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

# Launch the GUI
python "$PROJECT/interface/gui.py"

# Deactivate when closed
deactivate
