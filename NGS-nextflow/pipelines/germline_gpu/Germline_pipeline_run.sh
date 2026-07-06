#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(realpath "$PROJECT_DIR/../..")"
COHORT_NAME="$1"
FASTQ_PATH="$2"

# REF_DIR and RESULTS_DIR are required and must be set by the caller
# (run_pipeline_linux.sh prompts for these). No defaults are assumed.
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
echo " GERMLINE VARIANT CALLING PIPELINE"
echo "============================================"
echo " Reads     : $FASTQ_PATH"
echo " Reference : $REF_DIR"
echo " Results   : $RESULTS_DIR/$COHORT_NAME/"
echo "============================================"
echo ""

# Pre-flight GPU checks
if ! command -v nvidia-smi &> /dev/null; then
    echo "ERROR: nvidia-smi not found. This pipeline requires an NVIDIA GPU."
    echo "If you do not have an NVIDIA GPU, please use the CPU version of this pipeline."
    exit 1
fi

if ! docker info 2>/dev/null | grep -iq "Runtimes.*nvidia"; then
    echo "ERROR: NVIDIA Container Toolkit is not installed or configured in Docker."
    echo "Please install 'nvidia-container-toolkit' so Docker can access your GPU."
    exit 1
fi

# Auto-detect total host GPUs for accurate Nextflow scheduling
NUM_GPUS=$(nvidia-smi -L 2>/dev/null | wc -l || echo "1")
if ! [[ "$NUM_GPUS" =~ ^[0-9]+$ ]] || [ "$NUM_GPUS" -lt 1 ]; then
    NUM_GPUS=1
fi

# Auto-detect low memory requirement for GPUs with <= 24GB VRAM
GPU_MEM_MAX=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | sort -nr | head -n 1 || echo "0")
if [ "$GPU_MEM_MAX" -gt 0 ] && [ "$GPU_MEM_MAX" -le 25000 ]; then
    export LOW_MEMORY=1
    echo "INFO: Max GPU memory is ${GPU_MEM_MAX}MB (<= 24GB). Enabling Parabricks LOW_MEMORY mode to prevent OOM."
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

mkdir -p "$RESULTS_DIR/$COHORT_NAME"

APP_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
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
FQ2BAM_CPUS=$(clamp_cpu $CPU_COUNT 1)
HC_CPUS=$(clamp_cpu $CPU_COUNT 1)
GENO_CPUS=$(clamp_cpu $CPU_COUNT 1)
VARFILT_CPUS=$(clamp_cpu 2 1)
PASSVCF_CPUS=$(clamp_cpu 1 1)
FASTQC_MEM=$(clamp_mem $(( MEM_GB * 100 / 100 )) 2)
FQ2BAM_MEM=$(clamp_mem $(( MEM_GB * 60 / 100 )) 8)
HC_MEM=$(clamp_mem $(( MEM_GB * 60 / 100 )) 8)
GENO_MEM=$(clamp_mem $(( MEM_GB * 30 / 100 )) 4)
VARFILT_MEM=$(clamp_mem $(( MEM_GB * 10 / 100 )) 4)
PASSVCF_MEM=$(clamp_mem $(( MEM_GB * 5 / 100 )) 2)
FASTQC_MEM="${FASTQC_MEM} GB"
FQ2BAM_MEM="${FQ2BAM_MEM} GB"
HC_MEM="${HC_MEM} GB"
GENO_MEM="${GENO_MEM} GB"
VARFILT_MEM="${VARFILT_MEM} GB"
PASSVCF_MEM="${PASSVCF_MEM} GB"

MOUNTS=(
    -v "$APP_ROOT":"$APP_ROOT"
    -v "$FASTQ_PATH":"$FASTQ_PATH"
    -v "$REF_DIR":"$REF_DIR"
    -v "$RESULTS_DIR":"$RESULTS_DIR"
)

echo "DEBUG MOUNTS = ${MOUNTS[@]}" >&2
echo "DEBUG PROJECT_DIR = $PROJECT_DIR" >&2
ls -la "$PROJECT_DIR/Germline_pipeline.nf" >&2
docker run --rm \
    "${MOUNTS[@]}" \
    -w "$PROJECT_DIR" \
    --gpus all \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e NXF_DOCKER_LEGACY=true \
    nextflow/nextflow:26.04.3 \
    nextflow run Germline_pipeline.nf -c Germline_pipeline.config \
    -work-dir "$RESULTS_DIR/$COHORT_NAME/work" \
    --reads "${FASTQ_PATH}/*_R{1,2}.fastq.gz" \
    --reference "$REF_DIR/$REF_FASTA" \
    --outdir "$RESULTS_DIR/$COHORT_NAME" \
    --cohort_name "$COHORT_NAME" \
    --fastqc_cpus "$FASTQC_CPUS" \
    --fastqc_mem "$FASTQC_MEM" \
    --fq2bam_cpus "$FQ2BAM_CPUS" \
    --fq2bam_mem "$FQ2BAM_MEM" \
    --hc_cpus "$HC_CPUS" \
    --hc_mem "$HC_MEM" \
    --geno_cpus "$GENO_CPUS" \
    --geno_mem "$GENO_MEM" \
    --varfilt_cpus "$VARFILT_CPUS" \
    --varfilt_mem "$VARFILT_MEM" \
    --passvcf_cpus "$PASSVCF_CPUS" \
    --passvcf_mem "$PASSVCF_MEM" \
    --num_gpus "$NUM_GPUS" \
    ${LOW_MEMORY:+"--low_memory"} \
    -resume

# Restore ownership of output files from root to the host user
echo "Restoring file permissions..."
docker run --rm -v "$RESULTS_DIR":"$RESULTS_DIR" alpine chown -R $(id -u):$(id -g) "$RESULTS_DIR/$COHORT_NAME"

echo ""
echo "============================================"
echo " Results"
echo "============================================"
echo "GVCFs (per sample):"
ls -lh "$RESULTS_DIR/$COHORT_NAME/gvcf/" 2>/dev/null || echo "  None found"

echo ""
echo "VCFs (cohort):"
ls -lh "$RESULTS_DIR/$COHORT_NAME/vcf/" 2>/dev/null || echo "  None found"

echo ""
echo "Variant counts:"
RAW=$(grep -vc "^#" "$RESULTS_DIR/$COHORT_NAME/vcf/${COHORT_NAME}.vcf" 2>/dev/null || echo "0")
PASS=$(grep -vc "^#" "$RESULTS_DIR/$COHORT_NAME/vcf/${COHORT_NAME}.pass.vcf" 2>/dev/null || echo "0")
echo "  Raw variants  : $RAW"
echo "  PASS variants : $PASS"
echo ""
echo "Done!"


# Remove old Nextflow work directories (>7 days old)
find "$RESULTS_DIR/$COHORT_NAME/work" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -mtime +7 \
    -exec rm -rf {} +

echo "Old work directories cleaned."

echo ""
echo "Done!"
