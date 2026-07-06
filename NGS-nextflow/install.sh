#!/usr/bin/env bash
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo " BIOINFORMATICS APPLICATION"
echo " Global Installation"
echo "============================================"
echo

echo "[1/5] Creating directories..."

mkdir -p "$PROJECT/Data/Raw"
mkdir -p "$PROJECT/Data/Ref"
mkdir -p "$PROJECT/results"
mkdir -p "$PROJECT/work"
mkdir -p "$PROJECT/logs"

echo "Done."
echo

echo "[2/5] Making scripts executable..."

find "$PROJECT/pipelines" \
    -type f \
    -name "*.sh" \
    -exec chmod +x {} \;

chmod +x "$PROJECT/install.sh"
chmod +x "$PROJECT/cleanup.sh"
if [ -f "$PROJECT/run_singularity.sh" ]; then
    chmod +x "$PROJECT/run_singularity.sh"
fi
if [ -f "$PROJECT/install_singularity_gui.sh" ]; then
    chmod +x "$PROJECT/install_singularity_gui.sh"
fi

echo "Done."
echo

echo "[3/5] Setting up Python virtual environment and dependencies..."

if command -v python3 >/dev/null 2>&1; then
    python3 -m venv "$PROJECT/.venv"
    source "$PROJECT/.venv/bin/activate"
    pip install --upgrade pip
    if [ -f "$PROJECT/interface/requirements.txt" ]; then
        pip install -r "$PROJECT/interface/requirements.txt"
    fi
    deactivate
    echo "Python virtual environment created and dependencies installed."
else
    echo "WARNING: python3 is not installed. Skipping virtual environment creation."
fi
echo

echo "[4/5] Verifying Docker..."

if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
        echo "Docker OK."
    else
        echo "Docker is installed but not running or requires sudo."
    fi
else
    echo "Docker is not installed. Continuing..."
fi
echo

echo "[5/5] Pulling container images (if Docker is available)..."

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker pull nextflow/nextflow:26.04.3 || true
    docker pull biocontainers/fastqc:v0.11.9_cv8 || true
    docker pull biocontainers/bwa:v0.7.17_cv1 || true
    docker pull broadinstitute/gatk:4.6.2.0 || true
    docker pull staphb/bcftools:1.20 || true
    echo "Note: NVIDIA Parabricks image (nvcr.io/nvidia/clara/clara-parabricks:4.7.0-1) is large and is omitted from the default pull, but will be downloaded automatically during GPU pipeline execution."
else
    echo "Skipping Docker pull as Docker is not available or not running."
fi

echo
echo "Installation complete."
echo
echo "To run the GUI, please activate the virtual environment first:"
echo "  source .venv/bin/activate"
echo "  python interface/gui.py"
echo
echo "Host requirements:"
echo "  - Docker (or Singularity/Apptainer for HPC mode)"
echo "  - WSL2 (Windows only)"
echo "  - Python 3.8+ (for GUI)"
echo
echo "All bioinformatics tools are containerized."
