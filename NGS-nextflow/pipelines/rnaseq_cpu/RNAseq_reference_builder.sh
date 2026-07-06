#!/bin/bash
set -e

REF_DIR="$1"
REF_NAME="$2"
REF_GTF="$3"

if [[ -z "$REF_DIR" || -z "$REF_NAME" ]]; then
    echo "Usage: $0 <REF_DIR> <REF_NAME> [REF_GTF]"
    exit 1
fi

REF_FASTA="$REF_NAME.fasta"

if [[ ! -f "$REF_DIR/$REF_FASTA" ]]; then
    if [[ -f "$REF_DIR/$REF_NAME.fa" ]]; then
        REF_FASTA="$REF_NAME.fa"
    else
        echo "ERROR: $REF_FASTA or $REF_NAME.fa not found in $REF_DIR"
        exit 1
    fi
fi

REFERENCE="$REF_DIR/$REF_FASTA"

if [[ -z "$REF_GTF" ]]; then
    if [[ -f "$REF_DIR/$REF_NAME.gtf" ]]; then
        REF_GTF="$REF_DIR/$REF_NAME.gtf"
    else
        # Find any GTF in REF_DIR
        FOUND_GTF=$(ls "$REF_DIR"/*.gtf 2>/dev/null | head -n 1 || true)
        if [[ -n "$FOUND_GTF" ]]; then
            REF_GTF="$FOUND_GTF"
        else
            echo "ERROR: No GTF file specified or found in $REF_DIR. GTF is required for STAR indexing."
            exit 1
        fi
    fi
fi

if [[ ! -f "$REF_GTF" ]]; then
    echo "ERROR: GTF file not found at $REF_GTF"
    exit 1
fi

echo ""
echo "============================================"
echo " Building STAR Genome Index"
echo "============================================"
echo " Reference FASTA : $REFERENCE"
echo " Annotation GTF  : $REF_GTF"
echo " Output Dir      : $REF_DIR/star_index"
echo "============================================"
echo ""

mkdir -p "$REF_DIR/star_index"

# Detect CPUs
CPUS=$(nproc 2>/dev/null || echo 8)

echo "INFO: Running STAR --runMode genomeGenerate using $CPUS threads with sparse indexing (--genomeSAsparseD 2)..."

docker run --rm \
    -u "$(id -u):$(id -g)" \
    -v "$REF_DIR":"$REF_DIR" \
    -w "$REF_DIR" \
    quay.io/biocontainers/star:2.7.11a--h0033a41_0 \
    STAR --runMode genomeGenerate \
         --genomeDir "$REF_DIR/star_index" \
         --genomeFastaFiles "$REFERENCE" \
         --sjdbGTFfile "$REF_GTF" \
         --runThreadN "$CPUS" \
         --genomeSAindexNbases 14 \
         --genomeSAsparseD 2

# Fix for NVIDIA Parabricks compatibility: remove unrecognized parameters
if [[ -f "$REF_DIR/star_index/genomeParameters.txt" ]]; then
    sed -i '/genomeType/d' "$REF_DIR/star_index/genomeParameters.txt" 2>/dev/null || true
    sed -i '/genomeTransform/d' "$REF_DIR/star_index/genomeParameters.txt" 2>/dev/null || true
    sed -i 's/2.7.4a/2.7.1a/g' "$REF_DIR/star_index/genomeParameters.txt" 2>/dev/null || true
fi

echo ""
echo "STAR reference indexing complete!"
echo ""

touch "$REF_DIR/star_index/.star_index_complete"
