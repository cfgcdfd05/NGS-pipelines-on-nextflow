#!/usr/bin/env bash
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values (can be overridden via CLI flags or existing environment)
REF_DIR_VAL="${NGS_REF_DIR:-$PROJECT/Data/Ref}"
DATA_DIR_VAL="${NGS_DATA_DIR:-$PROJECT/Data/Raw}"
RESULTS_DIR_VAL="${NGS_RESULTS_DIR:-$PROJECT/results}"
WORK_DIR_VAL="${NGS_WORK_DIR:-$PROJECT/work}"
WSL_MOUNT_VAL="${NGS_WSL_MOUNT_PREFIX:-/mnt}"
CONTAINER_ENGINE_VAL="${NGS_CONTAINER_ENGINE:-auto}"

# Parse optional arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref-dir)
            REF_DIR_VAL="$2"; shift 2 ;;
        --data-dir)
            DATA_DIR_VAL="$2"; shift 2 ;;
        --results-dir)
            RESULTS_DIR_VAL="$2"; shift 2 ;;
        --work-dir)
            WORK_DIR_VAL="$2"; shift 2 ;;
        --wsl-mount)
            WSL_MOUNT_VAL="$2"; shift 2 ;;
        --container-engine)
            CONTAINER_ENGINE_VAL="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ./install.sh [options]"
            echo "Options:"
            echo "  --ref-dir <path>          Path to reference genome folder (default: $PROJECT/Data/Ref)"
            echo "  --data-dir <path>         Path to raw FASTQ folder (default: $PROJECT/Data/Raw)"
            echo "  --results-dir <path>      Path to output results folder (default: $PROJECT/results)"
            echo "  --work-dir <path>         Path to Nextflow work directory (default: $PROJECT/work)"
            echo "  --wsl-mount <prefix>      WSL drive mount prefix (default: /mnt)"
            echo "  --container-engine <eng>  Container engine: docker, singularity, apptainer, or auto"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1. Run with --help for options."
            exit 1
            ;;
    esac
done

echo "============================================"
echo " NGS NEXTFLOW GENOMICS SUITE"
echo " Universal System Configuration & Install"
echo "============================================"
echo ""

# Detect Operating System & WSL
OS_TYPE="$(uname -s)"
IS_WSL=0
if [[ -f /proc/version ]] && grep -qi "microsoft" /proc/version; then
    IS_WSL=1
fi

# Detect CPU Cores cross-platform
DETECTED_CPUS=4
if command -v nproc >/dev/null 2>&1; then
    DETECTED_CPUS=$(nproc)
elif command -v sysctl >/dev/null 2>&1; then
    DETECTED_CPUS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
fi

# Detect Memory GB cross-platform
DETECTED_RAM_GB=8
if [[ -f /proc/meminfo ]]; then
    DETECTED_RAM_GB=$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo)
elif command -v sysctl >/dev/null 2>&1; then
    MEM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 8589934592)
    DETECTED_RAM_GB=$(( MEM_BYTES / 1024 / 1024 / 1024 ))
fi

# Auto-detect container engine if requested
if [[ "$CONTAINER_ENGINE_VAL" == "auto" ]]; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        CONTAINER_ENGINE_VAL="docker"
    elif command -v apptainer >/dev/null 2>&1; then
        CONTAINER_ENGINE_VAL="apptainer"
    elif command -v singularity >/dev/null 2>&1; then
        CONTAINER_ENGINE_VAL="singularity"
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_ENGINE_VAL="docker"
    else
        CONTAINER_ENGINE_VAL="docker"
    fi
fi

# Check GPU availability
HAS_NVIDIA_GPU=0
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    HAS_NVIDIA_GPU=1
fi

echo "[1/5] Creating project directories..."
mkdir -p "$DATA_DIR_VAL"
mkdir -p "$REF_DIR_VAL"
mkdir -p "$RESULTS_DIR_VAL"
mkdir -p "$WORK_DIR_VAL"
mkdir -p "$PROJECT/logs"
echo "Done."
echo ""

echo "[2/5] Making executable scripts across project..."
find "$PROJECT" -type f -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
chmod +x "$PROJECT/install.sh"
echo "Done."
echo ""

echo "[3/5] Setting up Python virtual environment and dependencies..."
if command -v python3 >/dev/null 2>&1; then
    python3 -m venv "$PROJECT/.venv"
    source "$PROJECT/.venv/bin/activate"
    pip install --upgrade pip --quiet
    if [[ -f "$PROJECT/interface/requirements.txt" ]]; then
        pip install -r "$PROJECT/interface/requirements.txt" --quiet
    fi
    deactivate
    echo "Python virtual environment created (.venv) and dependencies installed."
else
    echo "WARNING: python3 not found. Skipping virtual environment setup."
fi
echo ""

echo "[4/5] Generating universal system configuration (system_config.env)..."
CONFIG_FILE="$PROJECT/system_config.env"
cat <<EOF > "$CONFIG_FILE"
# NGS Nextflow Genomics Suite - System Configuration
# Generated automatically by install.sh on $(date)
# This file ensures zero hardcoded system or directory paths.

export NGS_PROJECT_ROOT="$PROJECT"
export NGS_REF_DIR="$REF_DIR_VAL"
export NGS_DATA_DIR="$DATA_DIR_VAL"
export NGS_RESULTS_DIR="$RESULTS_DIR_VAL"
export NGS_WORK_DIR="$WORK_DIR_VAL"

export NGS_CONTAINER_ENGINE="$CONTAINER_ENGINE_VAL"
export NGS_WSL_MOUNT_PREFIX="$WSL_MOUNT_VAL"

export NGS_SYSTEM_OS="$OS_TYPE"
export NGS_SYSTEM_WSL="$IS_WSL"
export NGS_SYSTEM_MAX_CPUS="$DETECTED_CPUS"
export NGS_SYSTEM_MAX_RAM_GB="$DETECTED_RAM_GB"
export NGS_HAS_NVIDIA_GPU="$HAS_NVIDIA_GPU"
EOF

chmod 644 "$CONFIG_FILE"
echo "System configuration saved to: system_config.env"
echo ""

echo "[5/5] Checking container engine ($CONTAINER_ENGINE_VAL)..."
if [[ "$CONTAINER_ENGINE_VAL" == "docker" ]]; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo "Docker daemon is running and accessible."
    else
        echo "Note: Docker is selected or installed, but daemon is stopped or requires sudo."
    fi
elif [[ "$CONTAINER_ENGINE_VAL" =~ ^(singularity|apptainer)$ ]]; then
    if command -v "$CONTAINER_ENGINE_VAL" >/dev/null 2>&1; then
        echo "$CONTAINER_ENGINE_VAL is installed and ready."
    else
        echo "WARNING: $CONTAINER_ENGINE_VAL not found in PATH."
    fi
fi

GPU_STATUS="Not Detected"
if [[ "$HAS_NVIDIA_GPU" -eq 1 ]]; then
    GPU_STATUS="Available"
fi

echo ""
echo "=========================================================="
echo " Installation & System Configuration Complete!"
echo "=========================================================="
echo " Configured Parameters:"
echo "   Project Root     : $PROJECT"
echo "   Reference Folder : $REF_DIR_VAL"
echo "   FASTQ Folder     : $DATA_DIR_VAL"
echo "   Results Folder   : $RESULTS_DIR_VAL"
echo "   Container Engine : $CONTAINER_ENGINE_VAL"
echo "   Max CPU Cores    : $DETECTED_CPUS"
echo "   Max RAM (GB)     : $DETECTED_RAM_GB"
echo "   NVIDIA GPU       : $GPU_STATUS"
echo "=========================================================="
echo ""
echo "To launch the GUI interface:"
echo "  ./start_gui.sh"
echo ""
echo "To run the command-line interface:"
echo "  ./interface/main_menu.sh"
echo ""
