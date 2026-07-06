#!/bin/bash
set -e

echo "======================================================"
echo "   Nextflow Genomics Suite - Singularity Unlocker"
echo "======================================================"
echo ""
echo "This script unlocks the 'Singularity (HPC Mode)' feature"
echo "in the graphical user interface."
echo ""

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
touch "$PROJECT_DIR/.enable_singularity"

echo "SUCCESS: Singularity feature has been unlocked!"
echo "The next time you open the GUI, you will see the"
echo "'Use Singularity (HPC Mode)' checkbox in the settings."
echo ""
