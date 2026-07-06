# Germline Variant Calling Pipeline

GPU-accelerated germline variant calling pipeline using Nextflow DSL2 and
NVIDIA Parabricks. Supports single-sample and multi-sample cohort calling.

```
FastQC -> fq2bam -> HaplotypeCaller -> GenotypeGVCFs -> FilterVCF
```

## Requirements

- Linux or WSL2 with Docker installed
- NVIDIA GPU + nvidia-container-toolkit (`--gpus all` must work with `docker run`)
- Internet access to pull Docker images (~20GB total, mostly Parabricks)
- A reference genome (UCSC hg38 naming: chr1, chr2, ... chrM) with full index set:
  - `reference.fasta`
  - `reference.fasta.fai`
  - `reference.dict`
  - `reference.fasta.bwt` / `.amb` / `.ann` / `.pac` / `.sa`

## Files

| File | Purpose |
|---|---|
| `Germline_pipeline.nf` | Nextflow DSL2 pipeline definition |
| `Germline_pipeline.config` | Docker + GPU + resource configuration |
| `Germline_pipeline_run.sh` | Core launcher — runs Nextflow inside Docker |
| `Germline_pipeline_menu.sh` | Interactive menu (cohort name, FASTQ folder, validation) |
| `Germline_pipeline_install.sh` | One-time setup — creates folders, pulls Docker images |

## Installation

```bash
# 1. Run the installer (creates dirs + pulls Docker images)
bash Germline_pipeline_install.sh

# 2. Copy pipeline files into the project directory
cp Germline_pipeline.nf Germline_pipeline.config Germline_pipeline_run.sh Germline_pipeline_menu.sh ~/nextflow-project/

# 3. Place reference genome files
cp /path/to/reference.* ~/nextflow-project/data/ref/

# 4. Place FASTQ files (any folder you like)
cp /path/to/*_R1.fastq.gz /path/to/*_R2.fastq.gz ~/nextflow-project/data/raw/
```

## Running

```bash
cd ~/nextflow-project
bash Germline_pipeline_menu.sh
```

You'll be prompted for:
1. Cohort name (used to label output files and folders)
2. FASTQ folder path

Results are written to `~/nextflow-project/data/results/<cohort_name>/`:
- `fastqc/` — QC reports
- `bam/` — aligned, sorted, deduplicated BAMs
- `gvcf/` — per-sample GVCFs
- `vcf/` — `<cohort_name>.vcf` and `<cohort_name>.filtered.vcf`

## Custom data locations

To use a reference or output folder outside the project directory:

```bash
REF_DIR=/mnt/d/NextFlow/data/ref \
RESULTS_DIR=/mnt/d/NextFlow/results \
bash Germline_pipeline_run.sh my_cohort /mnt/d/NextFlow/data/raw
```

## Clearing cache

If a run fails partway through and `-resume` keeps reusing broken results:

```bash
sudo rm -rf ~/nextflow-project/work
```
