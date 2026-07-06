#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(realpath "$PROJECT_DIR/../..")"
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
echo " CHIP-SEQ GPU PIPELINE"
echo "============================================"
echo " Reads     : $FASTQ_PATH"
echo " Reference : $REF_DIR"
echo " Results   : $RESULTS_DIR/$PROJECT_NAME/"
echo "============================================"
echo ""

# Pre-flight GPU checks
if ! command -v nvidia-smi &> /dev/null; then
    echo "ERROR: nvidia-smi not found. This pipeline requires an NVIDIA GPU."
    echo "If you do not have an NVIDIA GPU, please use a CPU version of this pipeline."
    exit 1
fi

if ! docker info 2>/dev/null | grep -iq "Runtimes.*nvidia"; then
    echo "ERROR: NVIDIA Container Toolkit is not installed or configured in Docker."
    echo "Please install 'nvidia-container-toolkit' so Docker can access your GPU."
    exit 1
fi

# Auto-detect VRAM to prevent Out-Of-Memory (OOM) crashes
VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1)
if [ -n "$VRAM_MB" ] && [ "$VRAM_MB" -le 25000 ]; then
    echo "WARNING: GPU VRAM is <= 24GB (${VRAM_MB} MB detected)."
    echo "Automatically forcing Low Memory Mode to prevent crashes."
    export LOW_MEMORY="1"
fi

# Auto-detect total host GPUs for accurate Nextflow scheduling
NUM_GPUS=$(nvidia-smi -L 2>/dev/null | wc -l || echo "1")
if ! [[ "$NUM_GPUS" =~ ^[0-9]+$ ]] || [ "$NUM_GPUS" -lt 1 ]; then
    NUM_GPUS=1
fi

# Parabricks Auto Mode requires ~50GB of System RAM per concurrent fq2bam process.
# We must cap NUM_GPUS to physical RAM capacity to prevent OOM crashes on multi-GPU systems.
if command -v awk &> /dev/null && [ -f /proc/meminfo ]; then
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))
    # Subtract OS overhead (~20GB) before dividing
    ALLOWED_GPUS=$(( (TOTAL_RAM_GB - 20) / 50 ))
    [ "$ALLOWED_GPUS" -lt 1 ] && ALLOWED_GPUS=1
    
    if [ "$NUM_GPUS" -gt "$ALLOWED_GPUS" ]; then
        echo "WARNING: System RAM (${TOTAL_RAM_GB}GB) is insufficient to run ${NUM_GPUS} concurrent Parabricks tasks."
        echo "Capping concurrent GPUs to ${ALLOWED_GPUS} to prevent System OOM crashes."
        NUM_GPUS=$ALLOWED_GPUS
    fi
fi

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

FASTQC_CPUS=$(clamp_cpu $CPU_COUNT 1)
FASTP_CPUS=$(clamp_cpu $CPU_COUNT 1)
FQ2BAM_CPUS=$(clamp_cpu $CPU_COUNT 1)
MACS2_CPUS=$(clamp_cpu $CPU_COUNT 1)
FASTQC_MEM=$(clamp_mem $(( MEM_GB * 100 / 100 )) 2)
FASTP_MEM=$(clamp_mem $(( MEM_GB * 100 / 100 )) 4)
FQ2BAM_MEM=$(clamp_mem $(( MEM_GB * 60 / 100 )) 8)
MACS2_MEM=$(clamp_mem $(( MEM_GB * 30 / 100 )) 4)
FASTQC_MEM="${FASTQC_MEM} GB"
FASTP_MEM="${FASTP_MEM} GB"
FQ2BAM_MEM="${FQ2BAM_MEM} GB"
MACS2_MEM="${MACS2_MEM} GB"

MOUNTS=(
    -v "$APP_ROOT":"$APP_ROOT"
    -v "$FASTQ_PATH":"$FASTQ_PATH"
    -v "$REF_DIR":"$REF_DIR"
    -v "$RESULTS_DIR":"$RESULTS_DIR"
)

# Determine input args (samplesheet vs reads)
if [[ -n "$SAMPLESHEET" && -f "$SAMPLESHEET" ]]; then
    echo "INFO: Using samplesheet $SAMPLESHEET"
    INPUT_ARGS="--samplesheet $SAMPLESHEET"
    MOUNTS+=(-v "$SAMPLESHEET":"$SAMPLESHEET")
else
    echo "INFO: No samplesheet provided, using raw fastq pairs"
    INPUT_ARGS="--reads $FASTQ_PATH/*_R{1,2}.fastq.gz"
fi

echo "DEBUG MOUNTS = ${MOUNTS[@]}" >&2
echo "DEBUG PROJECT_DIR = $PROJECT_DIR" >&2

docker run --rm \
    "${MOUNTS[@]}" \
    -w "$PROJECT_DIR" \
    --gpus all \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e NXF_DOCKER_LEGACY=true \
    nextflow/nextflow:26.04.3 \
    nextflow run CHIPseq_GPU.nf -c CHIPseq_GPU.config \
    -work-dir "$RESULTS_DIR/$PROJECT_NAME/work" \
    $INPUT_ARGS \
    --reference "$REF_DIR/$REF_FASTA" \
    --outdir "$RESULTS_DIR/$PROJECT_NAME" \
    --project_name "$PROJECT_NAME" \
    --fastqc_cpus "$FASTQC_CPUS" \
    --fastqc_mem "$FASTQC_MEM" \
    --fastp_cpus "$FASTP_CPUS" \
    --fastp_mem "$FASTP_MEM" \
    --fq2bam_cpus "$FQ2BAM_CPUS" \
    --fq2bam_mem "$FQ2BAM_MEM" \
    --macs2_cpus "$MACS2_CPUS" \
    --macs2_mem "$MACS2_MEM" \
    --num_gpus "$NUM_GPUS" \
    ${LOW_MEMORY:+"--low_memory"} \
    -resume

# Restore ownership of output files from root to the host user
echo "Restoring file permissions..."
docker run --rm -v "$RESULTS_DIR":"$RESULTS_DIR" alpine chown -R $(id -u):$(id -g) "$RESULTS_DIR/$PROJECT_NAME"

echo ""
echo "============================================"
echo " Results"
echo "============================================"
echo "MACS2 Peak Calling (per sample):"
ls -lh "$RESULTS_DIR/$PROJECT_NAME/macs2/" 2>/dev/null || echo "  None found"

echo ""
echo "BAM files (per sample):"
ls -lh "$RESULTS_DIR/$PROJECT_NAME/bam/" 2>/dev/null || echo "  None found"

echo ""
echo "Done!"

# Remove old Nextflow work directories (>7 days old)
find "$RESULTS_DIR/$PROJECT_NAME/work" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -mtime +7 \
    -exec rm -rf {} +

echo "Old work directories cleaned."
