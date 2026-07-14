#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
if [[ -f "$APP_ROOT/system_config.env" ]]; then
    source "$APP_ROOT/system_config.env"
fi
PROJECT_NAME="$1"
FASTQ_PATH="$2"

if [[ -z "$REF_DIR" ]]; then
    echo "ERROR: REF_DIR is not set."
    exit 1
fi
if [[ -z "$RESULTS_DIR" ]]; then
    echo "ERROR: RESULTS_DIR is not set."
    exit 1
fi
REF_NAME="${REF_NAME:-reference}"
REF_FASTA="$REF_NAME.fasta"

if [[ ! -f "$REF_DIR/$REF_FASTA" ]]; then
    if [[ -f "$REF_DIR/$REF_NAME.fa" ]]; then
        REF_FASTA="$REF_NAME.fa"
    else
        echo "ERROR: $REF_FASTA or $REF_NAME.fa not found in $REF_DIR"
        exit 1
    fi
fi

if [[ -z "$REF_GTF" ]]; then
    REF_GTF="$REF_DIR/$REF_NAME.gtf"
fi

if [[ ! -f "$REF_GTF" ]]; then
    echo "ERROR: $REF_GTF not found. A GTF file is strictly required for RNA-seq."
    exit 1
fi

echo "============================================"
echo " RNA-SEQ CPU PIPELINE"
echo "============================================"
echo " Reads     : $FASTQ_PATH"
echo " Reference : $REF_DIR/$REF_FASTA"
echo " GTF       : $REF_GTF"
echo " Results   : $RESULTS_DIR/$PROJECT_NAME/"
echo "============================================"
echo ""

mkdir -p "$RESULTS_DIR/$PROJECT_NAME"
cd "$PROJECT_DIR"

PROFILE="docker"
if [[ "$USE_SINGULARITY" == "1" ]]; then
    PROFILE="singularity"
    export NXF_SINGULARITY_CACHEDIR="$APP_ROOT/singularity_cache"
    mkdir -p "$NXF_SINGULARITY_CACHEDIR"
fi

if [[ "${SKIP_INDEXING:-0}" == "1" ]]; then
    if [[ ! -d "$REF_DIR/star_index" ]]; then
        echo "ERROR: Pre-built STAR index option is selected (SKIP_INDEXING=1), but $REF_DIR/star_index directory was not found!"
        echo "Solution: Please click 'Build Reference Indexes' in the GUI first, or uncheck the 'Pre-built STAR index' option."
        exit 1
    fi
    echo "INFO: Using pre-built STAR index at $REF_DIR/star_index"
    STAR_INDEX_ARG="--star_index \"$REF_DIR/star_index\""
elif [[ -d "$REF_DIR/star_index" ]]; then
    echo "INFO: Using pre-built STAR index found at $REF_DIR/star_index"
    STAR_INDEX_ARG="--star_index \"$REF_DIR/star_index\""
else
    echo "INFO: No pre-built star_index found in $REF_DIR. The pipeline will build it on the fly."
    STAR_INDEX_ARG=""
fi

MOUNTS=(
    -v "$APP_ROOT":"$APP_ROOT"
    -v "$FASTQ_PATH":"$FASTQ_PATH"
    -v "$REF_DIR":"$REF_DIR"
    -v "$RESULTS_DIR":"$RESULTS_DIR"
)

# ── Run Nextflow Pipeline ──────────────────────────────────────────────────────
echo "Starting Nextflow pipeline..."
set -x

if [[ "$USE_SINGULARITY" == "1" ]]; then
    nextflow run RNAseq_CPU.nf \
        -c RNAseq_CPU.config \
        -profile $PROFILE \
        -work-dir "$RESULTS_DIR/$PROJECT_NAME/work" \
        --reads "$FASTQ_PATH/*_{R1,R2}*.{fastq,fq}.gz" \
        --reference "$REF_DIR/$REF_FASTA" \
        --gtf "$REF_GTF" \
        --outdir "$RESULTS_DIR/$PROJECT_NAME" \
        $STAR_INDEX_ARG \
        -resume
else
    docker run --rm \
        "${MOUNTS[@]}" \
        -w "$PROJECT_DIR" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e NXF_DOCKER_LEGACY=true \
        nextflow/nextflow:26.04.3 \
        bash -c "nextflow run RNAseq_CPU.nf \
            -c RNAseq_CPU.config \
            -profile $PROFILE \
            -work-dir \"$RESULTS_DIR/$PROJECT_NAME/work\" \
            --reads \"$FASTQ_PATH/*_{R1,R2}*.{fastq,fq}.gz\" \
            --reference \"$REF_DIR/$REF_FASTA\" \
            --gtf \"$REF_GTF\" \
            --outdir \"$RESULTS_DIR/$PROJECT_NAME\" \
            $STAR_INDEX_ARG \
            -resume"
    
    # Clean up ownership and restore permissions
    docker run --rm "${MOUNTS[@]}" -w "$RESULTS_DIR/$PROJECT_NAME" \
        --entrypoint bash nextflow/nextflow:26.04.3 -c "chown -R \$(id -u):\$(id -g) . && chmod -R u+rwX,g+rX,o+rX ."
fi

# Remove old Nextflow work directories (>7 days old)
find "$RESULTS_DIR/$PROJECT_NAME/work" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -mtime +7 \
    -exec rm -rf {} + 2>/dev/null

echo "Old work directories cleaned."

set +x

echo ""
echo "============================================"
echo " PIPELINE COMPLETED SUCCESSFULLY"
echo " Results are in: $RESULTS_DIR/$PROJECT_NAME/"
echo "============================================"
