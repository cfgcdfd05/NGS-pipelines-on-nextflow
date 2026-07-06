#!/bin/bash
set -e

echo "============================================"
echo " GERMLINE VARIANT CALLING PIPELINE"
echo " Installation"
echo "============================================"
echo ""

PROJECT="$HOME/nextflow-project"

# ── 1. Pull required Docker images ────────────────────────────────────────────
echo "[1/3] Pulling Docker images (this may take a while)..."
echo ""

echo "  -> nextflow/nextflow:26.04.3"
docker pull nextflow/nextflow:26.04.3

echo "  -> nvcr.io/nvidia/clara/clara-parabricks:4.7.0-1 (~15GB, GPU pipeline core)"
docker pull nvcr.io/nvidia/clara/clara-parabricks:4.7.0-1

echo "  -> biocontainers/fastqc:v0.11.9_cv8"
docker pull biocontainers/fastqc:v0.11.9_cv8

echo "  -> biocontainers/bcftools:v1.9-1-deb_cv1"
docker pull biocontainers/bcftools:v1.9-1-deb_cv1

echo "  -> biocontainers/samtools:v1.9-4-deb_cv1 (used for re-indexing if needed)"
docker pull biocontainers/samtools:v1.9-4-deb_cv1
echo ""

# ── 2. Check for GPU access ────────────────────────────────────────────────────
echo "[2/3] Checking GPU availability..."
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
else
    echo "  WARNING: nvidia-smi not found. GPU acceleration will not work without"
    echo "  NVIDIA drivers + nvidia-container-toolkit installed."
fi
echo ""

# ── 3. Reference genome check ──────────────────────────────────────────────────
echo "[3/3] Checking for reference genome..."
if [[ -f "$PROJECT/data/ref/reference.fasta" ]]; then
    echo "  Found: $PROJECT/data/ref/reference.fasta"
else
    echo "  NOT FOUND: $PROJECT/data/ref/reference.fasta"
    echo ""
    echo "  You must place the following files in $PROJECT/data/ref/ :"
    echo "    reference.fasta"
    echo "    reference.fasta.fai"
    echo "    reference.dict"
    echo "    reference.fasta.bwt"
    echo "    reference.fasta.amb"
    echo "    reference.fasta.ann"
    echo "    reference.fasta.pac"
    echo "    reference.fasta.sa"
    echo ""
    echo "  These must all use UCSC-style chromosome naming (chr1, chr2, ... chrM)"
    echo "  and originate from the SAME reference build (do not mix Ensembl + UCSC)."
fi
echo ""

echo "============================================"
echo " Installation complete!"
echo "============================================"
echo ""
echo " Project directory: $PROJECT"
echo ""
echo " Next steps:"
echo "   1. Copy Germline_pipeline.nf, Germline_pipeline.config, Germline_pipeline_run.sh, Germline_pipeline_menu.sh"
echo "      into: $PROJECT"
echo "   2. Place reference genome files into: $PROJECT/data/ref/"
echo "   3. Place input FASTQ files (sample_R1.fastq.gz / sample_R2.fastq.gz)"
echo "      into a folder of your choice (e.g. $PROJECT/data/raw/)"
echo "   4. Run:  bash $PROJECT/Germline_pipeline_menu.sh"
echo ""
