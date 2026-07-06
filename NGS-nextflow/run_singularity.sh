#!/bin/bash
set -e

echo "============================================"
echo "   Nextflow Genomics Suite - HPC/Singularity"
echo "============================================"
echo ""

# Pre-flight check for Java
if ! command -v java &> /dev/null; then
    echo "ERROR: Java is required to run Nextflow natively."
    echo "Please install Java (e.g., sudo apt install default-jre) and try again."
    exit 1
fi

# Pre-flight check for Singularity/Apptainer
if ! command -v singularity &> /dev/null && ! command -v apptainer &> /dev/null; then
    echo "ERROR: Singularity or Apptainer is not installed on this system."
    echo "Please install Singularity to use this Docker-less workflow."
    exit 1
fi

# Download Nextflow if missing
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

if [ ! -f "nextflow" ]; then
    echo "Nextflow executable not found. Downloading..."
    curl -s https://get.nextflow.io | bash
    chmod +x nextflow
    echo "Nextflow downloaded successfully."
    echo ""
fi

if [ "$#" -eq 5 ]; then
    PIPELINE_CHOICE=$1
    READS_DIR=$2
    REF_DIR=$3
    OUT_DIR=$4
    COHORT_NAME=$5
else
    # Interactive Select Pipeline
    echo "Select the pipeline you want to run:"
    echo "1) Germline Variant Calling (CPU-only)"
    echo "2) Germline Variant Calling (GPU Parabricks)"
    echo "3) ChIP-seq Peak Calling (GPU Parabricks)"
    read -p "Enter number (1/2/3): " PIPELINE_CHOICE
fi

case $PIPELINE_CHOICE in
    1)
        PIPELINE_NF="pipelines/germline_cpu/Germline_CPU.nf"
        PIPELINE_CFG="pipelines/germline_cpu/Germline_CPU.config"
        IS_GPU=false
        ;;
    2)
        PIPELINE_NF="pipelines/germline_gpu/Germline_pipeline.nf"
        PIPELINE_CFG="pipelines/germline_gpu/Germline_pipeline.config"
        IS_GPU=true
        ;;
    3)
        PIPELINE_NF="pipelines/chipseq/CHIPseq_GPU.nf"
        PIPELINE_CFG="pipelines/chipseq/CHIPseq_GPU.config"
        IS_GPU=true
        ;;
    4)
        PIPELINE_NF="pipelines/chipseq_cpu/CHIPseq_CPU.nf"
        PIPELINE_CFG="pipelines/chipseq_cpu/CHIPseq_CPU.config"
        IS_GPU=false
        ;;
    5)
        PIPELINE_NF="pipelines/rnaseq_cpu/RNAseq_CPU.nf"
        PIPELINE_CFG="pipelines/rnaseq_cpu/RNAseq_CPU.config"
        IS_GPU=false
        ;;
    6)
        PIPELINE_NF="pipelines/rnaseq_gpu/RNAseq_GPU.nf"
        PIPELINE_CFG="pipelines/rnaseq_gpu/RNAseq_GPU.config"
        IS_GPU=true
        ;;
    7)
        PIPELINE_NF="pipelines/somatic_cpu/Somatic_CPU.nf"
        PIPELINE_CFG="pipelines/somatic_cpu/Somatic_CPU.config"
        IS_GPU=false
        ;;
    8)
        PIPELINE_NF="pipelines/somatic_gpu/Somatic_GPU.nf"
        PIPELINE_CFG="pipelines/somatic_gpu/Somatic_GPU.config"
        IS_GPU=true
        ;;
    9)
        PIPELINE_NF="pipelines/scrnaseq_cpu/scRNAseq_CPU.nf"
        PIPELINE_CFG="pipelines/scrnaseq_cpu/scRNAseq_CPU.config"
        IS_GPU=false
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

if [ "$#" -ne 5 ]; then
    echo ""
    read -p "Enter path to FASTQ reads directory: " READS_DIR
    read -p "Enter path to Reference directory: " REF_DIR
    read -p "Enter path to Output results directory: " OUT_DIR
    read -p "Enter Cohort/Project Name: " COHORT_NAME
fi

# Convert to absolute paths
READS_DIR="$(realpath "$READS_DIR")"
REF_DIR="$(realpath "$REF_DIR")"
OUT_DIR="$(realpath "$OUT_DIR")"

echo ""
echo "Generating Singularity override configuration..."
cat <<EOF > .singularity.config
docker.enabled = false
singularity {
    enabled = true
    autoMounts = true
EOF

if [ "$IS_GPU" = true ]; then
    echo "    runOptions = '--nv'" >> .singularity.config
fi

echo "}" >> .singularity.config

echo "Configuration generated."
echo ""
echo "Launching Nextflow pipeline..."

# Ensure output directory exists
mkdir -p "$OUT_DIR/$COHORT_NAME"

GTF_ARG=""
if [[ -n "${REF_GTF:-}" ]]; then
    GTF_ARG="--gtf $REF_GTF"
fi

./nextflow run "$PIPELINE_NF" -c "$PIPELINE_CFG" -c .singularity.config \
    -work-dir "$OUT_DIR/$COHORT_NAME/work" \
    --reads "$READS_DIR/*_R{1,2}.fastq.gz" \
    --reference "$REF_DIR/reference.fasta" \
    --outdir "$OUT_DIR/$COHORT_NAME" \
    --cohort_name "$COHORT_NAME" \
    --project_name "$COHORT_NAME" \
    $GTF_ARG \
    -resume

echo "Pipeline execution completed."
