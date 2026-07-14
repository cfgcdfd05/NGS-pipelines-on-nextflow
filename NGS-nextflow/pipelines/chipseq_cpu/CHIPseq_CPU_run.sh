#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
if [[ -f "$APP_ROOT/system_config.env" ]]; then
    source "$APP_ROOT/system_config.env"
fi
PROJECT_NAME="$1"
FASTQ_PATH="$2"
SAMPLESHEET="$3"

# REF_DIR and RESULTS_DIR are required and must be set by the caller
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

echo "============================================"
echo " CHIP-SEQ CPU PIPELINE"
echo "============================================"
echo " Reads     : $FASTQ_PATH"
echo " Reference : $REF_DIR"
echo " Results   : $RESULTS_DIR/$PROJECT_NAME/"
echo "============================================"
echo ""

mkdir -p "$RESULTS_DIR/$PROJECT_NAME"

cd "$PROJECT_DIR"

# ── Build reference indexes if missing (BWA + samtools + GATK dict) ───────────
if [[ "${SKIP_INDEXING:-0}" == "1" ]]; then
    echo "Skipping index check (Pre-built indexes selected in UI)."
else
    DICT_NAME="${REF_NAME}.dict"
    
    # Check BWA index
    NEED_BWA=0
    for ext in bwt amb ann pac sa; do
        if [[ ! -f "$REF_DIR/${REF_FASTA}.$ext" && ! -f "$REF_DIR/${REF_NAME}.$ext" ]]; then
            NEED_BWA=1
        fi
    done
    
    if [[ "$NEED_BWA" -eq 1 ]]; then
        echo "BWA indexes missing or incomplete — building now..."
        docker run --rm -u "$(id -u):$(id -g)" -v "$REF_DIR":"$REF_DIR" -w "$REF_DIR" biocontainers/bwa:v0.7.17_cv1 bwa index "$REF_FASTA"
    fi

    # Check FAI
    if [[ ! -f "$REF_DIR/${REF_FASTA}.fai" && ! -f "$REF_DIR/${REF_NAME}.fai" ]]; then
        echo "FAI index missing — building now..."
        docker run --rm -u "$(id -u):$(id -g)" -v "$REF_DIR":"$REF_DIR" -w "$REF_DIR" broadinstitute/gatk:4.6.2.0 samtools faidx "$REF_FASTA"
    fi

    # Check DICT
    if [[ ! -f "$REF_DIR/$DICT_NAME" ]]; then
        echo "GATK dict missing — building now..."
        docker run --rm -u "$(id -u):$(id -g)" -v "$REF_DIR":"$REF_DIR" -w "$REF_DIR" broadinstitute/gatk:4.6.2.0 gatk CreateSequenceDictionary -R "$REF_FASTA" -O "$DICT_NAME"
    fi
fi

if [[ -n "${MAX_MEM_GB:-}" && "$MAX_MEM_GB" -gt 0 ]]; then
    MEM_GB=$MAX_MEM_GB
else
    MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_GB=$(( MEM_KB / 1024 / 1024 ))
    if [ "$MEM_GB" -gt 64 ]; then MEM_GB=64; fi
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
FASTP_CPUS=$(clamp_cpu $(( CPU_COUNT * 25 / 100 )) 2)
BWA_CPUS=$(clamp_cpu $(( CPU_COUNT * 60 / 100 )) 4)
SORT_CPUS=$(clamp_cpu $(( CPU_COUNT * 40 / 100 )) 2)
MARKDUP_CPUS=$(clamp_cpu $(( CPU_COUNT * 25 / 100 )) 2)
INDEX_CPUS=$(clamp_cpu $(( CPU_COUNT * 25 / 100 )) 2)
MACS2_CPUS=$(clamp_cpu $(( CPU_COUNT * 25 / 100 )) 2)
FASTQC_MEM=$(clamp_mem $(( MEM_GB * 10 / 100 )) 2)
FASTP_MEM=$(clamp_mem $(( MEM_GB * 10 / 100 )) 2)
BWA_MEM=$(clamp_mem $(( MEM_GB * 30 / 100 )) 8)
SORT_MEM=$(clamp_mem $(( MEM_GB * 20 / 100 )) 4)
MARKDUP_MEM=$(clamp_mem $(( MEM_GB * 20 / 100 )) 4)
MACS2_MEM=$(clamp_mem $(( MEM_GB * 20 / 100 )) 4)
FASTQC_MEM="${FASTQC_MEM} GB"
FASTP_MEM="${FASTP_MEM} GB"
BWA_MEM="${BWA_MEM} GB"
SORT_MEM="${SORT_MEM} GB"
MARKDUP_MEM="${MARKDUP_MEM} GB"
MACS2_MEM="${MACS2_MEM} GB"

MOUNTS=(
    -v "$APP_ROOT":"$APP_ROOT"
    -v "$FASTQ_PATH":"$FASTQ_PATH"
    -v "$REF_DIR":"$REF_DIR"
    -v "$RESULTS_DIR":"$RESULTS_DIR"
)

if [[ -f "$FASTQ_PATH/samplesheet.csv" && -z "$SAMPLESHEET" ]]; then
    SAMPLESHEET="$FASTQ_PATH/samplesheet.csv"
fi

if [[ -n "$SAMPLESHEET" && -f "$SAMPLESHEET" ]]; then
    INPUT_ARGS="--samplesheet \"$SAMPLESHEET\""
else
    INPUT_ARGS="--reads \"${FASTQ_PATH}/*_R{1,2}.fastq.gz\""
fi

# Run Nextflow
docker run --rm \
    "${MOUNTS[@]}" \
    -w "$PROJECT_DIR" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e NXF_DOCKER_LEGACY=true \
    nextflow/nextflow:26.04.3 \
    bash -c "nextflow run CHIPseq_CPU.nf -c CHIPseq_CPU.config \
        -work-dir \"$RESULTS_DIR/$PROJECT_NAME/work\" \
        -resume \
        $INPUT_ARGS \
        --reference \"$REF_DIR/$REF_FASTA\" \
        --outdir \"$RESULTS_DIR/$PROJECT_NAME\" \
        --project_name \"$PROJECT_NAME\" \
        --fastqc_cpus \"$FASTQC_CPUS\" \
        --fastqc_mem \"$FASTQC_MEM\" \
        --fastp_cpus \"$FASTP_CPUS\" \
        --fastp_mem \"$FASTP_MEM\" \
        --bwa_cpus \"$BWA_CPUS\" \
        --bwa_mem \"$BWA_MEM\" \
        --sort_cpus \"$SORT_CPUS\" \
        --sort_mem \"$SORT_MEM\" \
        --markdup_cpus \"$MARKDUP_CPUS\" \
        --markdup_mem \"$MARKDUP_MEM\" \
        --index_cpus \"$INDEX_CPUS\" \
        --macs2_cpus \"$MACS2_CPUS\" \
        --macs2_mem \"$MACS2_MEM\""

# Clean up ownership and restore permissions
docker run --rm "${MOUNTS[@]}" -w "$RESULTS_DIR/$PROJECT_NAME" \
    --entrypoint bash nextflow/nextflow:26.04.3 -c "chown -R $(id -u):$(id -g) . && chmod -R u+rwX,g+rX,o+rX ."

echo ""
echo "============================================"
echo " Results"
echo "============================================"
echo "MACS2 Peak Calling (per sample):"
ls -lh "$RESULTS_DIR/$PROJECT_NAME/macs2/" 2>/dev/null || echo "  None found"

echo ""
echo "BAM files (per sample):"
ls -lh "$RESULTS_DIR/$PROJECT_NAME/bam/" 2>/dev/null || echo "  None found"

echo "Done!"

# Remove old Nextflow work directories (>7 days old)
find "$RESULTS_DIR/$PROJECT_NAME/work" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -mtime +7 \
    -exec rm -rf {} + 2>/dev/null
echo "Old work directories cleaned."
