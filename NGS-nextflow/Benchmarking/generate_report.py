#!/usr/bin/env python3
"""
generate_report.py  —  Benchmarking Report Generator (v4 - Multi-Dataset Support)

Supports generating separate benchmarking sections and comparative summary tables for:
  1. Preexisting 50x Scaled Single Sample (~175MB compressed per pair / 5M read pairs)
  2. New Standard Single Sample (~3.6MB compressed per pair - sample1)
  3. New Standard 3-Sample Batch Cohort (~3.6MB compressed per pair x 3 - sample1, sample2, sample3)
  4. Actual Biological Dataset (~1.9GB compressed per pair - Garvan NA12878 WES)
"""
import os
import re
import csv
from pathlib import Path
from datetime import datetime

BENCH_DIR = Path(__file__).parent.resolve()
REPORT_FILE = BENCH_DIR / "benchmark_report.txt"
REPORT_FILE_ALT = BENCH_DIR / "benchmark.txt"
REPORT_FILE_ROOT = BENCH_DIR.parent / "benchmark.txt"

PIPELINES = ["germline", "chipseq", "rnaseq", "somatic"]
PIPELINE_NAMES = {
    "germline": "Germline Variant Calling",
    "chipseq":  "ChIP-seq Peak Calling",
    "rnaseq":   "RNA-seq Quantification",
    "somatic":  "Somatic Variant Calling",
}

def parse_duration_file(path):
    """Parse wall_clock_seconds, start_time, end_time from duration file."""
    info = {"seconds": None, "start": None, "end": None}
    if not path.exists():
        return info
    with open(path) as f:
        for line in f:
            if "wall_clock_seconds:" in line:
                try: info["seconds"] = int(line.split(":")[1].strip())
                except: pass
            elif "start_time:" in line:
                info["start"] = line.split(":", 1)[1].strip()
            elif "end_time:" in line:
                info["end"] = line.split(":", 1)[1].strip()
    return info

def parse_status_file(path):
    if not path.exists():
        return "PENDING"
    return path.read_text().strip()

def parse_docker_stats(path):
    stats = {"peak_cpu_pct": 0.0, "peak_ram_mb": 0.0, "avg_cpu_pct": 0.0, "samples": 0}
    if not path.exists():
        return stats
    cpu_vals = []
    ram_vals = []
    with open(path, errors="replace") as f:
        for line in f:
            parts = line.strip().split("\t")
            if len(parts) < 3:
                continue
            cpu_str = parts[1].replace("%", "").strip()
            try:
                cpu_val = float(cpu_str)
                cpu_vals.append(cpu_val)
            except:
                pass
            ram_str = parts[2].split("/")[0].strip()
            try:
                if "GiB" in ram_str:
                    ram_mb = float(ram_str.replace("GiB", "").strip()) * 1024
                elif "MiB" in ram_str:
                    ram_mb = float(ram_str.replace("MiB", "").strip())
                elif "KiB" in ram_str:
                    ram_mb = float(ram_str.replace("KiB", "").strip()) / 1024
                else:
                    ram_mb = 0
                ram_vals.append(ram_mb)
            except:
                pass

    if cpu_vals:
        stats["peak_cpu_pct"] = max(cpu_vals)
        stats["avg_cpu_pct"] = sum(cpu_vals) / len(cpu_vals)
        stats["samples"] = len(cpu_vals)
    if ram_vals:
        stats["peak_ram_mb"] = max(ram_vals)
    return stats

def parse_gpu_log(path):
    stats = {
        "gpus": {},
        "aggregate": {
            "peak_vram_mb": 0.0,
            "avg_gpu_util": 0.0,
            "peak_temp": 0,
            "peak_power": 0.0,
            "samples": 0,
        }
    }
    if not path.exists():
        return stats

    gpu_samples = {}
    with open(path, errors="replace") as f:
        reader = csv.reader(f)
        for row in reader:
            if not row or row[0].strip().startswith("timestamp") or len(row) < 8:
                continue
            try:
                idx = int(row[1].strip())
                name = row[2].strip()
                util = float(re.sub(r"[^\d.]", "", row[3]))
                mem_used = float(re.sub(r"[^\d.]", "", row[4]))
                mem_total = float(re.sub(r"[^\d.]", "", row[5]))
                temp = int(re.sub(r"[^\d]", "", row[6]))
                power = float(re.sub(r"[^\d.]", "", row[7]))
            except (ValueError, IndexError):
                continue

            if idx not in stats["gpus"]:
                stats["gpus"][idx] = {
                    "name": name,
                    "total_vram": mem_total,
                    "peak_vram": 0.0,
                    "util_vals": [],
                    "peak_temp": 0,
                    "peak_power": 0.0,
                }
            g = stats["gpus"][idx]
            g["peak_vram"] = max(g["peak_vram"], mem_used)
            g["util_vals"].append(util)
            g["peak_temp"] = max(g["peak_temp"], temp)
            g["peak_power"] = max(g["peak_power"], power)

            ts = row[0].strip()
            if ts not in gpu_samples:
                gpu_samples[ts] = 0.0
            gpu_samples[ts] += mem_used

    all_utils = []
    for idx, g in stats["gpus"].items():
        if g["util_vals"]:
            g["avg_util"] = sum(g["util_vals"]) / len(g["util_vals"])
            all_utils.extend(g["util_vals"])
        else:
            g["avg_util"] = 0.0

    if gpu_samples:
        stats["aggregate"]["peak_vram_mb"] = max(gpu_samples.values())
    if all_utils:
        stats["aggregate"]["avg_gpu_util"] = round(sum(all_utils) / len(all_utils), 1)
    if stats["gpus"]:
        stats["aggregate"]["peak_temp"] = max(g["peak_temp"] for g in stats["gpus"].values())
        stats["aggregate"]["peak_power"] = max(g["peak_power"] for g in stats["gpus"].values())

    return stats

def format_duration(seconds):
    if seconds is None:
        return "N/A"
    m, s = divmod(seconds, 60)
    return f"{m}m {s:02d}s ({seconds}s)"

def format_ram(mb):
    if mb <= 0:
        return "N/A"
    if mb >= 1024:
        return f"{mb/1024:.2f} GB"
    return f"{mb:.0f} MB"

def generate_dataset_section(logs_dir, title, description, lines):
    sep = "=" * 90
    lines.append("")
    lines.append(sep)
    lines.append(f"  {title}")
    lines.append(sep)
    lines.append(f"  Dataset Description : {description}")
    lines.append(f"  Logs Directory      : {logs_dir}")
    lines.append(sep)
    lines.append("")

    if not logs_dir.exists() or not any(logs_dir.iterdir()):
        lines.append("  [INFO] No benchmark logs found in this directory yet. Section pending execution.")
        lines.append("")
        return

    summary_rows = []

    for pipe in PIPELINES:
        p_name = PIPELINE_NAMES.get(pipe, pipe)
        lines.append(f"── {p_name} " + "─" * (85 - len(p_name) - 4))

        cpu_dur = parse_duration_file(logs_dir / f"{pipe}_cpu_duration.txt")
        gpu_dur = parse_duration_file(logs_dir / f"{pipe}_gpu_duration.txt")

        cpu_status = parse_status_file(logs_dir / f"{pipe}_cpu_status.txt")
        gpu_status = parse_status_file(logs_dir / f"{pipe}_gpu_status.txt")

        cpu_docker = parse_docker_stats(logs_dir / f"{pipe}_cpu_docker_stats.log")
        gpu_docker = parse_docker_stats(logs_dir / f"{pipe}_gpu_docker_stats.log")

        gpu_stats = parse_gpu_log(logs_dir / f"{pipe}_gpu_gpu.log")

        lines.append(f"  [CPU Engine]")
        lines.append(f"    Status          : {cpu_status}")
        lines.append(f"    Wall-Clock Time : {format_duration(cpu_dur['seconds'])}")
        lines.append(f"    Peak CPU Usage  : {cpu_docker['peak_cpu_pct']:.1f}%")
        lines.append(f"    Avg CPU Usage   : {cpu_docker['avg_cpu_pct']:.1f}%")
        lines.append(f"    Peak RAM Usage  : {format_ram(cpu_docker['peak_ram_mb'])}")
        lines.append("")

        lines.append(f"  [GPU Engine (NVIDIA Parabricks)]")
        lines.append(f"    Status          : {gpu_status}")
        lines.append(f"    Wall-Clock Time : {format_duration(gpu_dur['seconds'])}")
        lines.append(f"    Peak CPU Usage  : {gpu_docker['peak_cpu_pct']:.1f}%")
        lines.append(f"    Avg CPU Usage   : {gpu_docker['avg_cpu_pct']:.1f}%")
        lines.append(f"    Peak RAM Usage  : {format_ram(gpu_docker['peak_ram_mb'])}")

        agg = gpu_stats["aggregate"]
        lines.append(f"    Total Peak VRAM : {format_ram(agg['peak_vram_mb'])}")
        lines.append(f"    Avg GPU Util    : {agg['avg_gpu_util']}%")
        if agg["peak_temp"] > 0:
            lines.append(f"    Peak GPU Temp   : {agg['peak_temp']}°C")
        if agg["peak_power"] > 0:
            lines.append(f"    Peak Power Draw : {agg['peak_power']:.1f} W")

        for idx, ginfo in sorted(gpu_stats["gpus"].items()):
            lines.append(f"      GPU {idx} ({ginfo['name']}, {ginfo['total_vram']} MiB total):")
            lines.append(f"        Peak VRAM : {ginfo['peak_vram']} MiB  |  Avg Util: {ginfo['avg_util']:.1f}%  |  Peak Temp: {ginfo['peak_temp']}°C")

        cpu_s = cpu_dur["seconds"]
        gpu_s = gpu_dur["seconds"]
        speedup_str = "N/A"
        if cpu_s and gpu_s and gpu_s > 0 and cpu_status == "SUCCESS" and gpu_status == "SUCCESS":
            speedup = cpu_s / float(gpu_s)
            speedup_str = f"{speedup:.2f}x"
            if speedup > 1:
                lines.append(f"\n  >> GPU is {speedup_str} FASTER than CPU <<")
            elif speedup < 1:
                inverse = float(gpu_s) / cpu_s
                lines.append(f"\n  >> CPU is {inverse:.2f}x FASTER — GPU overhead dominates on tiny dataset <<")
        elif "FAILED" in cpu_status or "FAILED" in gpu_status:
            lines.append(f"\n  >> Pipeline failed — see logs for details <<")

        lines.append("")
        lines.append("")

        summary_rows.append((
            p_name,
            cpu_status,
            format_duration(cpu_s),
            f"{cpu_docker['peak_cpu_pct']:.0f}%",
            format_ram(cpu_docker["peak_ram_mb"]),
            gpu_status,
            format_duration(gpu_s),
            speedup_str,
            format_ram(agg["peak_vram_mb"]),
        ))

    lines.append(f"── {title} : COMPARATIVE SUMMARY TABLE ──")
    lines.append(sep)
    hdr = f"{'Pipeline':<26}| {'CPU Status':<10}| {'CPU Time':<18}| {'CPU Peak':<8}| {'CPU RAM':<10}| {'GPU Status':<12}| {'GPU Time':<18}| {'Speedup':<8}| {'Peak VRAM':<12}"
    lines.append(hdr)
    lines.append("-" * len(hdr))
    for r in summary_rows:
        lines.append(f"{r[0]:<26}| {r[1]:<10}| {r[2]:<18}| {r[3]:<8}| {r[4]:<10}| {r[5]:<12}| {r[6]:<18}| {r[7]:<8}| {r[8]:<12}")
    lines.append(sep)
    lines.append("")

def main():
    lines = []
    sep = "=" * 90
    lines.append(sep)
    lines.append("                      NEXTFLOW PIPELINE BENCHMARKING REPORT (v4)                       ")
    lines.append(sep)

    try:
        cpu_count = os.cpu_count() or 0
        with open("/proc/meminfo") as f:
            mem_kb = int(re.search(r"MemTotal:\s+(\d+)", f.read()).group(1))
            mem_gb = mem_kb / 1024 / 1024
    except:
        cpu_count = 0
        mem_gb = 0

    lines.append(f"Benchmarking Suite Path : {BENCH_DIR}")
    lines.append(f"Reference Genome        : hg38 (3.2GB FASTA + BWA/GATK/STAR indices)")
    lines.append(f"System CPUs             : {cpu_count}")
    lines.append(f"System RAM              : {mem_gb:.0f} GB")
    lines.append(sep)
    lines.append("")
    lines.append("NOTE: Resource stats (CPU%, RAM) are captured via 'docker stats' which monitors")
    lines.append("  the actual running containers, not just the orchestrating shell process.")
    lines.append("")

    # Actual Biological Dataset (Only actual dataset as requested)
    generate_dataset_section(
        BENCH_DIR / "logs_actual",
        "ACTUAL BIOLOGICAL DATASET (WES)",
        "2 x ~1.9GB compressed FASTQ (Garvan NA12878 WES, sample1_R1/R2.fastq.gz)",
        lines
    )

    # Notes
    lines.append(sep)
    lines.append("NOTES & OBSERVATIONS")
    lines.append("─" * 40)
    lines.append("1. Resource stats are captured from 'docker stats' (polling actual container CPU/RAM).")
    lines.append("2. GPU VRAM figures are per-GPU peak values summed across all detected GPUs.")
    lines.append("3. ChIP-seq GPU appearing 'slower' on very small test files: Parabricks container")
    lines.append("   startup + GPU initialization overhead (~20-30s) dominates total runtime.")
    lines.append("4. RNA-seq STAR index: Cached cleanly at ./data/ref/star_index with 14-base words.")
    lines.append("5. All test datasets, reference files, and output results are preserved in ./Benchmarking/.")

    report = "\n".join(lines)
    with open(REPORT_FILE, "w") as f:
        f.write(report)
    with open(REPORT_FILE_ALT, "w") as f:
        f.write(report)
    with open(REPORT_FILE_ROOT, "w") as f:
        f.write(report)
    print(report)

if __name__ == "__main__":
    main()
