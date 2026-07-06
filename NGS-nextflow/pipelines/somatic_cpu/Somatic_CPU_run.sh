#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COHORT_NAME="$1"
FASTQ_PATH="$2"

# REF_DIR and RESULTS_DIR are required and must be set by the caller
# (Somatic_CPU_menu.sh prompts for these). No defaults are assumed.
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
echo " SOMATIC CPU VARIANT CALLING PIPELINE"
echo "============================================"
echo " Reads     : $FASTQ_PATH"
echo " Reference : $REF_DIR"
echo " Results   : $RESULTS_DIR/$COHORT_NAME/"
echo "============================================"
echo ""

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

FASTQC_CPUS=$(clamp_cpu $(( CPU_COUNT * 25 / 100 )) 2)
BWA_CPUS=$(clamp_cpu $(( CPU_COUNT * 60 / 100 )) 4)
SORT_CPUS=$(clamp_cpu $(( CPU_COUNT * 40 / 100 )) 2)
MARKDUP_CPUS=$(clamp_cpu $SORT_CPUS 1)
MUTECT2_CPUS=$(clamp_cpu $(( CPU_COUNT * 60 / 100 )) 4)
FILTER_CPUS=$(clamp_cpu 2 1)
PASSVCF_CPUS=$(clamp_cpu 1 1)
FASTQC_MEM=$(clamp_mem $(( MEM_GB * 10 / 100 )) 2)
BWA_MEM=$(clamp_mem $(( MEM_GB * 40 / 100 )) 8)
SORT_MEM=$(clamp_mem $(( MEM_GB * 20 / 100 )) 4)
MARKDUP_MEM=$(clamp_mem $(( MEM_GB * 20 / 100 )) 4)
MUTECT2_MEM=$(clamp_mem $(( MEM_GB * 40 / 100 )) 8)
FILTER_MEM=$(clamp_mem $(( MEM_GB * 10 / 100 )) 4)
PASSVCF_MEM=$(clamp_mem $(( MEM_GB * 5 / 100 )) 2)
FASTQC_MEM="${FASTQC_MEM} GB"
BWA_MEM="${BWA_MEM} GB"
SORT_MEM="${SORT_MEM} GB"
MARKDUP_MEM="${MARKDUP_MEM} GB"
MUTECT2_MEM="${MUTECT2_MEM} GB"
FILTER_MEM="${FILTER_MEM} GB"
PASSVCF_MEM="${PASSVCF_MEM} GB"

MOUNTS=(
    -v "$APP_ROOT":"$APP_ROOT"
    -v "$FASTQ_PATH":"$FASTQ_PATH"
    -v "$REF_DIR":"$REF_DIR"
    -v "$RESULTS_DIR":"$RESULTS_DIR"
)

docker run --rm \
    "${MOUNTS[@]}" \
    -w "$PROJECT_DIR" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e NXF_DOCKER_LEGACY=true \
    nextflow/nextflow:26.04.3 \
    nextflow run Somatic_CPU.nf -c Somatic_CPU.config \
    -work-dir "$RESULTS_DIR/$COHORT_NAME/work" \
    --reads "${FASTQ_PATH}/*_R{1,2}.fastq.gz" \
    --reference "$REF_DIR/$REF_FASTA" \
    --outdir "$RESULTS_DIR/$COHORT_NAME" \
    --cohort_name "$COHORT_NAME" \
    --fastqc_cpus "$FASTQC_CPUS" \
    --fastqc_mem "$FASTQC_MEM" \
    --bwa_cpus "$BWA_CPUS" \
    --bwa_mem "$BWA_MEM" \
    --sort_cpus "$SORT_CPUS" \
    --sort_mem "$SORT_MEM" \
    --markdup_cpus "$MARKDUP_CPUS" \
    --markdup_mem "$MARKDUP_MEM" \
    --mutect2_cpus "$MUTECT2_CPUS" \
    --mutect2_mem "$MUTECT2_MEM" \
    --filter_cpus "$FILTER_CPUS" \
    --filter_mem "$FILTER_MEM" \
    --passvcf_cpus "$PASSVCF_CPUS" \
    --passvcf_mem "$PASSVCF_MEM" \
    -resume

# Restore ownership of output files from root to the host user
echo "Restoring file permissions..."
docker run --rm -v "$RESULTS_DIR":"$RESULTS_DIR" alpine chown -R $(id -u):$(id -g) "$RESULTS_DIR/$COHORT_NAME"

echo ""
echo "============================================"
echo " Results"
echo "============================================"
echo "BAMs (per sample):"
ls -lh "$RESULTS_DIR/$COHORT_NAME/bam/"*.bam 2>/dev/null || echo "  None found"

echo ""
echo "VCFs (per sample):"
ls -lh "$RESULTS_DIR/$COHORT_NAME/vcf/" 2>/dev/null || echo "  None found"

echo ""
echo "Variant counts (per sample):"
for passvcf in "$RESULTS_DIR/$COHORT_NAME/vcf/"*.pass.vcf.gz; do
    if [[ -f "$passvcf" ]]; then
        SAMPLE=$(basename "$passvcf" .pass.vcf.gz)
        RAW=$(zgrep -vc "^#" "$RESULTS_DIR/$COHORT_NAME/vcf/${SAMPLE}.mutect2.vcf.gz" 2>/dev/null || echo "0")
        FILT=$(zgrep -vc "^#" "$RESULTS_DIR/$COHORT_NAME/vcf/${SAMPLE}.filtered.vcf.gz" 2>/dev/null || echo "0")
        PASS=$(zgrep -vc "^#" "$passvcf" 2>/dev/null || echo "0")
        echo "  ${SAMPLE}:"
        echo "    Raw variants      : $RAW"
        echo "    Filtered variants : $FILT"
        echo "    PASS variants     : $PASS"
    fi
done
echo ""

# Remove old Nextflow work directories (>7 days old)
find "$RESULTS_DIR/$COHORT_NAME/work" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -mtime +7 \
    -exec rm -rf {} + 2>/dev/null

echo "Old work directories cleaned."

echo ""
echo "Done!"
