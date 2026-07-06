# ChIP-seq GPU Pipeline (Parabricks + MACS2)

This directory contains the GPU-accelerated ChIP-seq variant calling pipeline. It utilizes NVIDIA Clara Parabricks for ultra-fast GPU alignment (`fq2bam`), and MACS2 for peak calling.

## Prerequisites

- **Docker** must be installed and running.
- **NVIDIA GPU** with appropriate drivers and the NVIDIA Container Toolkit installed.
- **Nextflow** is handled automatically via a Docker container in the run script.

## Directory Structure

Ensure your reference genome directory contains the following files (assuming your reference is named `hg38.fasta`):
- `hg38.fasta`
- `hg38.fasta.fai` (FASTA index)
- `hg38.dict` (Sequence dictionary)
- `hg38.bwt`, `hg38.ann`, `hg38.amb`, `hg38.pac`, `hg38.sa` (BWA index files)

Ensure your FASTQ directory contains your paired-end reads ending in `_R1.fastq.gz` and `_R2.fastq.gz`.

### Using Controls (Input DNA)

To utilize Input DNA controls for MACS2 peak calling, create a file named `samplesheet.csv` in your FASTQ directory with the following exact header:
```csv
sample,fastq_1,fastq_2,control
treat1,/path/to/treat1_R1.fastq.gz,/path/to/treat1_R2.fastq.gz,input1
treat2,/path/to/treat2_R1.fastq.gz,/path/to/treat2_R2.fastq.gz,input1
input1,/path/to/input1_R1.fastq.gz,/path/to/input1_R2.fastq.gz,
```
If `samplesheet.csv` is not present, all `*_R1.fastq.gz` files will be treated as individual ChIP samples without a background control.

## How to Run

1. Open a terminal.
2. Navigate to this directory.
3. Run the interactive menu script:
   ```bash
   bash CHIPseq_GPU_menu.sh
   ```
4. Follow the prompts to specify your project name, reference genome folder, and FASTQ folder.

## Outputs

Results will be generated in `../../results/<project_name>/` (relative to this directory) with the following subdirectories:
- `fastqc/` - Quality control reports for raw reads.
- `fastp/` - Quality control and trimming reports.
- `bam/` - Aligned, sorted, and duplicate-marked BAM files (and indices).
- `macs2/` - Called peaks (narrowPeak, summits.bed, excel/bedgraph files).

## Troubleshooting

- **No BAM generated:** Ensure your BWA index files are present in the reference directory. Parabricks `fq2bam` requires them.
- **Permission errors:** The pipeline runs Nextflow inside Docker and maps your user ID/group ID to ensure resulting files are owned by you. If you get permission denied errors on the output folder, check that you have write access to `../results/`.
