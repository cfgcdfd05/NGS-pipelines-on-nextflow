#!/bin/bash
set -e

REF_DIR="$1"
REF_NAME="$2"

if [[ -z "$REF_DIR" || -z "$REF_NAME" ]]; then
    echo "Usage: $0 <REF_DIR> <REF_NAME>"
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

echo ""
echo "Reference:"
echo "$REFERENCE"
echo ""

docker run --rm \
    -u "$(id -u):$(id -g)" \
    -v "$REF_DIR":"$REF_DIR" \
    -w "$REF_DIR" \
    biocontainers/bwa:v0.7.17_cv1 \
    bwa index "$REF_FASTA"

docker run --rm \
    -u $(id -u):$(id -g) \
    -v "$REF_DIR":"$REF_DIR" \
    -w "$REF_DIR" \
    broadinstitute/gatk:4.6.2.0 \
    samtools faidx "$REF_FASTA"

DICT_NAME="${REF_NAME}.dict"

docker run --rm \
    -u $(id -u):$(id -g) \
    -v "$REF_DIR":"$REF_DIR" \
    -w "$REF_DIR" \
    broadinstitute/gatk:4.6.2.0 \
    gatk CreateSequenceDictionary \
        -R "$REF_FASTA" \
        -O "$DICT_NAME"

echo ""
echo "Reference indexing complete."
echo ""


touch "${REFERENCE}.cpu_index_complete"