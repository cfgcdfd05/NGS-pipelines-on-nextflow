#!/bin/bash
###############################################################################
# run_actual_benchmark.sh — Benchmarking Suite for Actual Biological Dataset
#
# Runs all 8 Nextflow pipeline configurations against human reference hg38
# using real biological sequencing data (NIST GIAB NA12878 WES).
###############################################################################
set -u

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(realpath "$BENCH_DIR/..")"
cd "$BENCH_DIR"

export LOG_DIR="${LOG_DIR:-$BENCH_DIR/logs_actual}"
export RESULTS_DIR="${RESULTS_DIR:-$BENCH_DIR/results_actual}"
export REF_DIR="$BENCH_DIR/data/ref"
export REF_NAME="hg38"
export REF_GTF="$REF_DIR/hg38.gtf"
export SKIP_INDEXING="1"
export LOW_MEMORY="1"
export MAX_CPUS="${MAX_CPUS:-$(nproc)}"
export MAX_MEM_GB="${MAX_MEM_GB:-$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)}"

FASTQ_DIR="${FASTQ_DIR:-$BENCH_DIR/data/raw_actual}"

mkdir -p "$RESULTS_DIR" "$LOG_DIR" work

echo "=========================================================="
echo " Nextflow Pipeline Benchmarking - Actual Dataset"
echo "=========================================================="
echo " Project Root : $PROJECT_ROOT"
echo " Benchmarking : $BENCH_DIR"
echo " FASTQ Input  : $FASTQ_DIR (Garvan NA12878 WES)"
echo " Reference    : $REF_DIR ($REF_NAME)"
echo " System CPUs  : $MAX_CPUS"
echo " System RAM   : ${MAX_MEM_GB} GB"
echo "=========================================================="

GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
GPU_NAMES=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | paste -sd "; " || echo "None")
echo " GPUs         : $GPU_COUNT ($GPU_NAMES)"
echo "=========================================================="

run_pipeline_bench() {
    local name="$1"
    local type="$2"  # cpu or gpu
    local script_path="$3"
    shift 3
    local args=("$@")

    echo ""
    echo "----------------------------------------------------------"
    echo " Benchmarking: $name ($type)"
    echo " Script      : $script_path"
    echo " Started     : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "----------------------------------------------------------"

    local log_prefix="$LOG_DIR/${name}_${type}"

    if [[ -f "${log_prefix}_status.txt" ]] && grep -q "SUCCESS" "${log_prefix}_status.txt"; then
        echo " [SKIP] $name ($type) already completed successfully. Keeping existing logs and duration."
        return 0
    fi

    local gpu_pid=""
    local docker_pid=""

    if [[ "$type" == "gpu" ]]; then
        nvidia-smi --query-gpu=timestamp,index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv -l 1 > "${log_prefix}_gpu.log" 2>/dev/null &
        gpu_pid=$!
    fi

    (
        while true; do
            docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null >> "${log_prefix}_docker_stats.log"
            sleep 2
        done
    ) &
    docker_pid=$!

    local start_time=$(date +%s)
    local start_ts=$(date '+%Y-%m-%d %H:%M:%S')

    if bash "$script_path" "bench_actual_${name}_${type}" "$FASTQ_DIR" "${args[@]}" > "${log_prefix}_out.log" 2>&1; then
        echo " [SUCCESS] $name ($type) completed without error."
        echo "SUCCESS" > "${log_prefix}_status.txt"
    else
        local ec=$?
        echo " [FAILED]  $name ($type) exit code $ec — see ${log_prefix}_out.log"
        echo "FAILED ($ec)" > "${log_prefix}_status.txt"
        echo " [CLEANUP] Error occurred! Deleting useless intermediate files..."
        find "$PROJECT_ROOT" -name "work" -type d -prune -exec rm -rf {} + 2>/dev/null || true
        find "$PROJECT_ROOT" -name "*.sam" -type f -delete 2>/dev/null || true
        mkdir -p "$PROJECT_ROOT/work" "$BENCH_DIR/work"
    fi

    local end_time=$(date +%s)
    local end_ts=$(date '+%Y-%m-%d %H:%M:%S')
    local duration=$((end_time - start_time))

    cat > "${log_prefix}_duration.txt" <<EOF
wall_clock_seconds: ${duration}
start_time: ${start_ts}
end_time: ${end_ts}
EOF

    echo " Finished    : $end_ts  (${duration}s)"

    kill "$docker_pid" 2>/dev/null || true
    if [[ -n "$gpu_pid" ]] && kill -0 "$gpu_pid" 2>/dev/null; then
        kill "$gpu_pid" 2>/dev/null || true
    fi

    echo " [CLEANUP] Post-run cleanup of work directories and intermediate .sam files..."
    find "$PROJECT_ROOT" -name "work" -type d -prune -exec rm -rf {} + 2>/dev/null || true
    find "$PROJECT_ROOT" -name "*.sam" -type f -delete 2>/dev/null || true
    mkdir -p "$PROJECT_ROOT/work" "$BENCH_DIR/work"

    echo " [REPORT] Updating benchmark.txt..."
    python3 "$BENCH_DIR/generate_report.py" >/dev/null 2>&1 || true
}

# 1. Germline CPU & GPU
run_pipeline_bench "germline" "cpu" "$PROJECT_ROOT/pipelines/germline_cpu/Germline_CPU_run.sh"
run_pipeline_bench "germline" "gpu" "$PROJECT_ROOT/pipelines/germline_gpu/Germline_pipeline_run.sh"

# 2. ChIP-seq CPU & GPU
run_pipeline_bench "chipseq" "cpu" "$PROJECT_ROOT/pipelines/chipseq_cpu/CHIPseq_CPU_run.sh" ""
run_pipeline_bench "chipseq" "gpu" "$PROJECT_ROOT/pipelines/chipseq/CHIPseq_GPU_run.sh" ""

# 3. RNA-seq CPU & GPU
if [[ -f "${REF_DIR}/star_index/genomeParameters.txt" ]]; then
    sed -i 's/2\.7\.1a/2.7.4a/g' "${REF_DIR}/star_index/genomeParameters.txt" 2>/dev/null || true
fi
run_pipeline_bench "rnaseq" "cpu" "$PROJECT_ROOT/pipelines/rnaseq_cpu/RNAseq_CPU_run.sh"
if [[ -f "${REF_DIR}/star_index/genomeParameters.txt" ]]; then
    sed -i '/genomeType/d' "${REF_DIR}/star_index/genomeParameters.txt" 2>/dev/null || true
    sed -i '/genomeTransform/d' "${REF_DIR}/star_index/genomeParameters.txt" 2>/dev/null || true
    sed -i 's/2\.7\.4a/2.7.1a/g' "${REF_DIR}/star_index/genomeParameters.txt" 2>/dev/null || true
fi
run_pipeline_bench "rnaseq" "gpu" "$PROJECT_ROOT/pipelines/rnaseq_gpu/RNAseq_GPU_run.sh"

# 4. Somatic CPU & GPU
run_pipeline_bench "somatic" "cpu" "$PROJECT_ROOT/pipelines/somatic_cpu/Somatic_CPU_run.sh"
run_pipeline_bench "somatic" "gpu" "$PROJECT_ROOT/pipelines/somatic_gpu/Somatic_GPU_run.sh"

echo ""
echo "=========================================================="
echo " Actual biological dataset benchmarking runs completed!"
echo "=========================================================="
