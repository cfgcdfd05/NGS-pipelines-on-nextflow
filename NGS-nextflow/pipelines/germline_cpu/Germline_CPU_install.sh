#!/bin/bash
set -e

echo "============================================"
echo " GERMLINE CPU VARIANT CALLING PIPELINE"
echo " Installation"
echo "============================================"
echo ""

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ── 1. Pull required Docker images ────────────────────────────────────────────
echo "[1/2] Pulling Docker images (this may take a while)..."
echo ""

echo "  -> nextflow/nextflow:26.04.3"
docker pull nextflow/nextflow:26.04.3

echo "  -> biocontainers/fastqc:v0.11.9_cv8"
docker pull biocontainers/fastqc:v0.11.9_cv8

echo "  -> biocontainers/bwa:v0.7.17_cv1"
docker pull biocontainers/bwa:v0.7.17_cv1


echo "  -> broadinstitute/gatk:4.6.2.0"
docker pull broadinstitute/gatk:4.6.2.0


# ── 2. Reference genome check ──────────────────────────────────────────────────
echo "[2/2] Checking for reference genome..."
if [[ -f "$PROJECT/Data/Ref/reference.fasta" ]]; then
    echo "  Found: $PROJECT/Data/Ref/reference.fasta"
else
    echo "  NOT FOUND: $PROJECT/Data/Ref/reference.fasta"
    echo ""
    echo "  You must place the following files in $PROJECT/Data/Ref/ :"
    echo "    reference.fasta"
    echo "    reference.fasta.fai"
    echo "    reference.dict"
    echo "    reference.fasta.bwt"
    echo "    reference.fasta.amb"
    echo "    reference.fasta.ann"
    echo "    reference.fasta.pac"
    echo "    reference.fasta.sa"
    echo ""
    echo "  If only reference.fasta is present, the pipeline menu will build"
    echo "  the remaining index files automatically on first run."
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
echo "   1. Copy Germline_CPU.nf, Germline_CPU.config, Germline_CPU_run.sh, Germline_CPU_menu.sh"
echo "      into: $PROJECT"
echo "   2. Place reference genome files into: $PROJECT/data/ref/"
echo "   3. Place input FASTQ files (sample_R1.fastq.gz / sample_R2.fastq.gz)"
echo "      into a folder of your choice (e.g. $PROJECT/data/raw/)"
echo "   4. Run:  bash $PROJECT/Germline_CPU_menu.sh"
echo ""
