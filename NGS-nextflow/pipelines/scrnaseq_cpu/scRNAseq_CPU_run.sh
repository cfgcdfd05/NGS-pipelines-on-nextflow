#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
if [[ -f "$APP_ROOT/system_config.env" ]]; then
    source "$APP_ROOT/system_config.env"
fi
PROJECT_NAME="$1"
FASTQ_PATH="$2"

if [[ -z "$PROJECT_NAME" || -z "$FASTQ_PATH" ]]; then
    echo "Usage: $0 <project_name> <fastq_path>"
    exit 1
fi

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
    echo "ERROR: $REF_GTF not found. A GTF file is strictly required for scRNA-seq."
    exit 1
fi

echo "============================================"
echo " SINGLE-CELL RNA-SEQ PIPELINE"
echo "============================================"
echo " Reads     : $FASTQ_PATH"
echo " Reference : $REF_DIR/$REF_FASTA"
echo " GTF       : $REF_GTF"
echo " Results   : $RESULTS_DIR/$PROJECT_NAME/"
echo "============================================"
echo ""

mkdir -p "$RESULTS_DIR/$PROJECT_NAME"
cd "$PROJECT_DIR"

# ── Detect system resources ───────────────────────────────────────────────────
if [[ -n "${MAX_MEM_GB:-}" && "$MAX_MEM_GB" -gt 0 ]]; then
    MEM_GB=$MAX_MEM_GB
else
    MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_GB=$(( MEM_KB / 1024 / 1024 ))
    if [ "$MEM_GB" -gt 128 ]; then MEM_GB=128; fi
fi

if [[ -n "${MAX_CPUS:-}" && "$MAX_CPUS" -gt 0 ]]; then
    CPU_COUNT=$MAX_CPUS
else
    CPU_COUNT=$(nproc)
fi

clamp_cpu() {
    local val=$1
    local min=$2
    [ "$val" -lt "$min" ] && val=$min
    [ "$val" -gt "$CPU_COUNT" ] && val=$CPU_COUNT
    echo "$val"
}

clamp_mem() {
    local val=$1
    local min=$2
    [ "$val" -lt "$min" ] && val=$min
    [ "$val" -gt "$MEM_GB" ] && val=$MEM_GB
    echo "$val"
}

FASTQC_CPUS=$(clamp_cpu $(( CPU_COUNT * 25 / 100 )) 2)
STAR_IDX_CPUS=$(clamp_cpu $(( CPU_COUNT * 75 / 100 )) 4)
STARSOLO_CPUS=$(clamp_cpu $(( CPU_COUNT * 75 / 100 )) 4)
SUMMARIZE_CPUS=$(clamp_cpu 1 1)

FASTQC_MEM=$(clamp_mem $(( MEM_GB * 10 / 100 )) 2)
STAR_IDX_MEM=$(clamp_mem $(( MEM_GB * 70 / 100 )) 32)
STARSOLO_MEM=$(clamp_mem $(( MEM_GB * 70 / 100 )) 32)
SUMMARIZE_MEM=$(clamp_mem $(( MEM_GB * 5 / 100 )) 2)

FASTQC_MEM="${FASTQC_MEM} GB"
STAR_IDX_MEM="${STAR_IDX_MEM} GB"
STARSOLO_MEM="${STARSOLO_MEM} GB"
SUMMARIZE_MEM="${SUMMARIZE_MEM} GB"

echo "Resources detected: ${CPU_COUNT} CPUs, ${MEM_GB} GB RAM"
echo "  FastQC    : ${FASTQC_CPUS} CPUs, ${FASTQC_MEM}"
echo "  STAR idx  : ${STAR_IDX_CPUS} CPUs, ${STAR_IDX_MEM}"
echo "  STARsolo  : ${STARSOLO_CPUS} CPUs, ${STARSOLO_MEM}"
echo "  Summarize : ${SUMMARIZE_CPUS} CPUs, ${SUMMARIZE_MEM}"
echo ""

# ── Build STAR genome index if missing ────────────────────────────────────────
if [[ "${SKIP_INDEXING:-0}" == "1" ]]; then
    if [[ ! -d "$REF_DIR/star_index" ]]; then
        echo "ERROR: Pre-built STAR index option is selected (SKIP_INDEXING=1), but $REF_DIR/star_index directory was not found!"
        echo "Solution: Please click 'Build Reference Indexes' in the GUI first, or uncheck the 'Pre-built STAR index' option."
        exit 1
    fi
    echo "Skipping index check (Pre-built indexes selected in UI)."
elif [[ ! -f "$REF_DIR/star_index/SA" ]]; then
    echo "STAR genome index not found (no SA file in $REF_DIR/star_index)."
    echo "Building STAR genome index — this may take a while for large genomes..."
    mkdir -p "$REF_DIR/star_index"
    docker run --rm -u "$(id -u):$(id -g)" \
        -v "$REF_DIR":"$REF_DIR" \
        quay.io/biocontainers/star:2.7.11a--h0033a41_0 \
        STAR --runMode genomeGenerate \
             --genomeDir "$REF_DIR/star_index" \
             --genomeFastaFiles "$REF_DIR/$REF_FASTA" \
             --sjdbGTFfile "$REF_GTF" \
             --runThreadN "$STAR_IDX_CPUS" \
             --genomeSAsparseD 2
    echo "STAR genome index built successfully."
else
    echo "STAR genome index found at $REF_DIR/star_index/"
fi

# ── Determine STAR index path ────────────────────────────────────────────────
STAR_INDEX_ARG=""
if [[ -d "$REF_DIR/star_index" ]]; then
    STAR_INDEX_ARG="--star_index \"$REF_DIR/star_index\""
fi

# ── Whitelist argument ────────────────────────────────────────────────────────
WHITELIST_ARG=""
if [[ -n "${WHITELIST:-}" && -f "$WHITELIST" ]]; then
    WHITELIST_ARG="--whitelist \"$WHITELIST\""
fi

# ── Container profile ────────────────────────────────────────────────────────
PROFILE="docker"
if [[ "$USE_SINGULARITY" == "1" ]]; then
    PROFILE="singularity"
    export NXF_SINGULARITY_CACHEDIR="$APP_ROOT/singularity_cache"
    mkdir -p "$NXF_SINGULARITY_CACHEDIR"
fi

# ── Mounts ────────────────────────────────────────────────────────────────────
MOUNTS=(
    -v "$APP_ROOT":"$APP_ROOT"
    -v "$FASTQ_PATH":"$FASTQ_PATH"
    -v "$REF_DIR":"$REF_DIR"
    -v "$RESULTS_DIR":"$RESULTS_DIR"
)
# Mount whitelist file if external
if [[ -n "${WHITELIST:-}" && -f "$WHITELIST" ]]; then
    MOUNTS+=(-v "$(dirname "$WHITELIST")":"$(dirname "$WHITELIST")")
fi

# ── Run Nextflow Pipeline ────────────────────────────────────────────────────
echo "Starting Nextflow pipeline..."
set -x

if [[ "$USE_SINGULARITY" == "1" ]]; then
    nextflow run scRNAseq_CPU.nf \
        -c scRNAseq_CPU.config \
        -profile $PROFILE \
        -work-dir "$RESULTS_DIR/$PROJECT_NAME/work" \
        --reads "$FASTQ_PATH/*_R{1,2}.fastq.gz" \
        --reference "$REF_DIR/$REF_FASTA" \
        --gtf "$REF_GTF" \
        --outdir "$RESULTS_DIR/$PROJECT_NAME" \
        --project_name "$PROJECT_NAME" \
        --fastqc_cpus "$FASTQC_CPUS" \
        --fastqc_mem "$FASTQC_MEM" \
        --star_idx_cpus "$STAR_IDX_CPUS" \
        --star_idx_mem "$STAR_IDX_MEM" \
        --starsolo_cpus "$STARSOLO_CPUS" \
        --starsolo_mem "$STARSOLO_MEM" \
        --summarize_cpus "$SUMMARIZE_CPUS" \
        --summarize_mem "$SUMMARIZE_MEM" \
        $STAR_INDEX_ARG \
        $WHITELIST_ARG \
        -resume
else
    docker run --rm \
        "${MOUNTS[@]}" \
        -w "$PROJECT_DIR" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e NXF_DOCKER_LEGACY=true \
        nextflow/nextflow:26.04.3 \
        bash -c "nextflow run scRNAseq_CPU.nf \
            -c scRNAseq_CPU.config \
            -profile $PROFILE \
            -work-dir \"$RESULTS_DIR/$PROJECT_NAME/work\" \
            --reads \"$FASTQ_PATH/*_R{1,2}.fastq.gz\" \
            --reference \"$REF_DIR/$REF_FASTA\" \
            --gtf \"$REF_GTF\" \
            --outdir \"$RESULTS_DIR/$PROJECT_NAME\" \
            --project_name \"$PROJECT_NAME\" \
            --fastqc_cpus \"$FASTQC_CPUS\" \
            --fastqc_mem \"$FASTQC_MEM\" \
            --star_idx_cpus \"$STAR_IDX_CPUS\" \
            --star_idx_mem \"$STAR_IDX_MEM\" \
            --starsolo_cpus \"$STARSOLO_CPUS\" \
            --starsolo_mem \"$STARSOLO_MEM\" \
            --summarize_cpus \"$SUMMARIZE_CPUS\" \
            --summarize_mem \"$SUMMARIZE_MEM\" \
            $STAR_INDEX_ARG \
            $WHITELIST_ARG \
            -resume"

    # Restore ownership of output files
    echo "Restoring file permissions..."
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
echo " Results"
echo "============================================"
echo "STARsolo output:"
ls -lh "$RESULTS_DIR/$PROJECT_NAME/starsolo/" 2>/dev/null || echo "  None found"

echo ""
echo "FastQC reports:"
ls -lh "$RESULTS_DIR/$PROJECT_NAME/fastqc/" 2>/dev/null || echo "  None found"

echo ""
echo "Summary reports:"
ls -lh "$RESULTS_DIR/$PROJECT_NAME/summary/" 2>/dev/null || echo "  None found"

# ── Clean up old Nextflow work directories ────────────────────────────────────
if [[ -d "$RESULTS_DIR/$PROJECT_NAME/work" ]]; then
    find "$RESULTS_DIR/$PROJECT_NAME/work" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -mtime +7 \
        -exec rm -rf {} + 2>/dev/null
    echo ""
    echo "Old work directories cleaned."
fi

echo ""
echo "============================================"
echo " PIPELINE COMPLETED SUCCESSFULLY"
echo " Results are in: $RESULTS_DIR/$PROJECT_NAME/"
echo "============================================"
