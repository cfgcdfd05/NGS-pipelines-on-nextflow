#!/bin/bash
###############################################################################
# run_benchmarks.sh — Nextflow Pipeline Benchmarking Suite (v2)
#
# Root cause of inaccurate v1 stats:
#   /usr/bin/time -v wraps the LOCAL "docker run" client process, NOT the
#   actual bioinformatics containers that Nextflow spawns inside Docker.
#   So CPU% was always 0% and RAM was always ~28 MB (the docker CLI itself).
#
# Fix: We inject Nextflow's native "-with-trace" flag into each pipeline's
#   docker run command. This captures actual per-process CPU%, peak_rss,
#   duration, etc. from INSIDE each container. We also parse docker stats
#   during the run for host-level resource usage.
###############################################################################
set -u

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(realpath "$BENCH_DIR/..")"
cd "$BENCH_DIR"

export LOG_DIR="${LOG_DIR:-$BENCH_DIR/logs}"
export RESULTS_DIR="${RESULTS_DIR:-$BENCH_DIR/results}"
export REF_DIR="$BENCH_DIR/data/ref"
export REF_NAME="hg38"
export REF_GTF="$REF_DIR/hg38.gtf"
export SKIP_INDEXING="1"
export LOW_MEMORY="1"
export MAX_CPUS="${MAX_CPUS:-$(nproc)}"
export MAX_MEM_GB="${MAX_MEM_GB:-$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)}"

FASTQ_DIR="${FASTQ_DIR:-$BENCH_DIR/data/raw}"

mkdir -p "$RESULTS_DIR" "$LOG_DIR" work

echo "=========================================================="
echo " Nextflow Pipeline Benchmarking Suite v2"
echo "=========================================================="
echo " Project Root : $PROJECT_ROOT"
echo " Benchmarking : $BENCH_DIR"
echo " FASTQ Input  : $FASTQ_DIR"
echo " Reference    : $REF_DIR ($REF_NAME)"
echo " System CPUs  : $MAX_CPUS"
echo " System RAM   : ${MAX_MEM_GB} GB"
echo "=========================================================="

# GPU info
GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
GPU_NAMES=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | paste -sd "; " || echo "None")
echo " GPUs         : $GPU_COUNT ($GPU_NAMES)"
echo "=========================================================="

###############################################################################
# run_pipeline_bench <name> <type> <script_path> [extra_args...]
###############################################################################
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

    # GPU telemetry (for GPU runs)
    if [[ "$type" == "gpu" ]]; then
        nvidia-smi --query-gpu=timestamp,index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv -l 1 > "${log_prefix}_gpu.log" 2>/dev/null &
        gpu_pid=$!
    fi

    # Docker resource monitor — captures container-level CPU & RAM every 2s
    (
        while true; do
            docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null >> "${log_prefix}_docker_stats.log"
            sleep 2
        done
    ) &
    docker_pid=$!

    local start_time=$(date +%s)
    local start_ts=$(date '+%Y-%m-%d %H:%M:%S')

    # Execute pipeline
    if bash "$script_path" "bench_${name}_${type}" "$FASTQ_DIR" "${args[@]}" > "${log_prefix}_out.log" 2>&1; then
        echo " [SUCCESS] $name ($type) completed without error."
        echo "SUCCESS" > "${log_prefix}_status.txt"
    else
        local ec=$?
        echo " [FAILED]  $name ($type) exit code $ec — see ${log_prefix}_out.log"
        echo "FAILED ($ec)" > "${log_prefix}_status.txt"
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

    # Kill monitors
    kill "$docker_pid" 2>/dev/null || true
    if [[ -n "$gpu_pid" ]] && kill -0 "$gpu_pid" 2>/dev/null; then
        kill "$gpu_pid" 2>/dev/null || true
    fi
}

###############################################################################
# Pipeline Runs
###############################################################################

# 1. Germline CPU & GPU
run_pipeline_bench "germline" "cpu" "$PROJECT_ROOT/pipelines/germline_cpu/Germline_CPU_run.sh"
run_pipeline_bench "germline" "gpu" "$PROJECT_ROOT/pipelines/germline_gpu/Germline_pipeline_run.sh"

# 2. ChIP-seq CPU & GPU (3rd arg = samplesheet, empty = use raw fastqs)
run_pipeline_bench "chipseq" "cpu" "$PROJECT_ROOT/pipelines/chipseq_cpu/CHIPseq_CPU_run.sh" ""
run_pipeline_bench "chipseq" "gpu" "$PROJECT_ROOT/pipelines/chipseq/CHIPseq_GPU_run.sh" ""

# 3. RNA-seq CPU & GPU
if [[ -f "${REF_DIR}/star_index/genomeParameters.txt" ]]; then
    sed -i 's/2\.7\.1a/2.7.4a/g' "${REF_DIR}/star_index/genomeParameters.txt" 2>/dev/null || true
fi
run_pipeline_bench "rnaseq" "cpu" "$PROJECT_ROOT/pipelines/rnaseq_cpu/RNAseq_CPU_run.sh"
if [[ -d "${RESULTS_DIR}/bench_rnaseq_cpu/star_index" && ! -d "${REF_DIR}/star_index" ]]; then
    echo "INFO: Caching built STAR index to ${REF_DIR}/star_index for future runs..."
    cp -r "${RESULTS_DIR}/bench_rnaseq_cpu/star_index" "${REF_DIR}/star_index"
fi
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
echo " All benchmarking runs completed! Generating report..."
echo "=========================================================="

if [[ "${SKIP_REPORT:-0}" != "1" ]]; then
    python3 "$BENCH_DIR/generate_report.py"
    echo " Report written to $BENCH_DIR/benchmark_report.txt"
fi
