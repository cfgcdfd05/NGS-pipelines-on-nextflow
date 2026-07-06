#!/bin/bash
set -e

# Interactive CLI Menu for RNAseq CPU Pipeline

read -p "Enter Project Name: " proj_name
read -p "Enter FASTQ Folder Path: " fastq_path
read -p "Enter Reference Folder Path: " ref_dir
read -p "Enter Reference Base Name (e.g. hg38): " ref_name
read -p "Enter Results Directory Path: " res_dir
read -p "Use Singularity instead of Docker? (y/n): " use_singularity

export REF_DIR="$ref_dir"
export RESULTS_DIR="$res_dir"
export REF_NAME="$ref_name"

if [[ "$use_singularity" == "y" || "$use_singularity" == "Y" ]]; then
    export USE_SINGULARITY=1
else
    export USE_SINGULARITY=0
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$DIR/RNAseq_GPU_run.sh" "$proj_name" "$fastq_path"
