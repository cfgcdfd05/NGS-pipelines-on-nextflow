#!/usr/bin/env nextflow

/*
 * Single-Cell RNA-seq Pipeline — CPU-based (STARsolo)
 * Steps: FastQC → STARsolo (Alignment + Quantification) → Summarize
 *
 * Designed for 10x Genomics Chromium v3 data.
 * FASTQ naming: *_R1.fastq.gz (barcode+UMI), *_R2.fastq.gz (cDNA)
 */

nextflow.enable.dsl = 2

// ── Parameters ───────────────────────────────────────────────────────────────
params.project_name     = "scrnaseq_project"
params.reads            = null
params.reference        = null
params.gtf              = null
params.outdir           = null
params.star_index       = null
params.whitelist        = null

params.fastqc_cpus      = null
params.fastqc_mem       = null
params.star_idx_cpus    = null
params.star_idx_mem     = null
params.starsolo_cpus    = null
params.starsolo_mem     = null
params.summarize_cpus   = null
params.summarize_mem    = null

params.fastqc_image     = "biocontainers/fastqc:v0.11.9_cv8"
params.star_image       = "quay.io/biocontainers/star:2.7.11a--h0033a41_0"
params.python_image     = "python:3.9-slim"

// ── Process 1: FastQC ─────────────────────────────────────────────────────────
process FASTQC {
    tag "$sample_id"
    publishDir "${params.outdir}/fastqc", mode: 'copy'
    container params.fastqc_image
    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple val(sample_id), path(reads)

    output:
    tuple val(sample_id), path("*.html"), emit: html
    tuple val(sample_id), path("*.zip"),  emit: zip

    script:
    """
    echo "INFO: Running FastQC for ${sample_id}"
    fastqc ${reads[0]} ${reads[1]} \
        --threads ${task.cpus} \
        --outdir .
    """
}

// ── Process 2: STAR Genome Index (conditional) ────────────────────────────────
process STAR_INDEX {
    tag "STAR_index"
    publishDir "${params.outdir}/star_index", mode: 'copy'
    container params.star_image

    input:
    path fasta
    path gtf

    output:
    path "star_index", emit: index

    script:
    """
    mkdir -p star_index
    STAR --runMode genomeGenerate \
         --genomeDir star_index \
         --genomeFastaFiles ${fasta} \
         --sjdbGTFfile ${gtf} \
         --runThreadN ${task.cpus}
    """
}

// ── Process 3: STARsolo ───────────────────────────────────────────────────────
process STARSOLO {
    tag "$sample_id"
    publishDir "${params.outdir}/starsolo", mode: 'copy'
    container params.star_image
    errorStrategy 'retry'
    maxRetries 1

    input:
    tuple val(sample_id), path(reads)
    path index
    path gtf
    path whitelist

    output:
    tuple val(sample_id), path("${sample_id}_Solo.out"),                              emit: solo_out
    tuple val(sample_id), path("${sample_id}_Aligned.sortedByCoord.out.bam"),         emit: bam
    tuple val(sample_id), path("${sample_id}_Log.final.out"),                         emit: log

    script:
    """
    echo "INFO: STARsolo alignment for ${sample_id}"

    STAR --runMode alignReads \
         --soloType CB_UMI_Simple \
         --genomeDir ${index} \
         --readFilesIn ${reads[1]} ${reads[0]} \
         --readFilesCommand zcat \
         --soloCBwhitelist ${whitelist} \
         --outSAMtype BAM SortedByCoordinate \
         --outSAMattributes NH HI nM AS CR UR CB UB GX GN sS sQ sM \
         --soloFeatures Gene GeneFull \
         --soloCBstart 1 \
         --soloCBlen 16 \
         --soloUMIstart 17 \
         --soloUMIlen 12 \
         --soloBarcodeReadLength 0 \
         --outFilterMultimapNmax 1 \
         --runThreadN ${task.cpus} \
         --sjdbGTFfile ${gtf} \
         --outFileNamePrefix ${sample_id}_

    [ -s "${sample_id}_Aligned.sortedByCoord.out.bam" ] || {
        echo "ERROR: empty BAM file"
        exit 1
    }
    """
}

// ── Process 4: Summarize ──────────────────────────────────────────────────────
process SUMMARIZE {
    tag "$sample_id"
    publishDir "${params.outdir}/summary", mode: 'copy'
    container params.python_image
    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple val(sample_id), path(solo_out)

    output:
    tuple val(sample_id), path("${sample_id}_summary.txt"), emit: summary

    script:
    """
    #!/usr/bin/env python3
    import os, gzip, sys
    from pathlib import Path

    sample = "${sample_id}"
    solo_dir = Path("${solo_out}")

    # Try Gene/filtered first, then Gene/raw, then GeneFull
    matrix_file = None
    features_file = None
    barcodes_file = None

    for sub in ["Gene/filtered", "GeneFull/filtered", "Gene/raw", "GeneFull/raw"]:
        candidate = solo_dir / sub
        if candidate.exists():
            # Look for matrix file (could be .mtx or .mtx.gz)
            for mf in ["matrix.mtx.gz", "matrix.mtx"]:
                if (candidate / mf).exists():
                    matrix_file = candidate / mf
                    break
            for ff in ["features.tsv.gz", "features.tsv", "genes.tsv.gz", "genes.tsv"]:
                if (candidate / ff).exists():
                    features_file = candidate / ff
                    break
            for bf in ["barcodes.tsv.gz", "barcodes.tsv"]:
                if (candidate / bf).exists():
                    barcodes_file = candidate / bf
                    break
            if matrix_file:
                break

    out = open(f"{sample}_summary.txt", "w")
    out.write(f"=== Single-Cell RNA-seq Summary: {sample} ===\\n\\n")

    # Parse STARsolo Summary.csv if available
    for sub in ["Gene/filtered", "GeneFull/filtered", "Gene/raw", "GeneFull/raw"]:
        summary_csv = solo_dir / sub / "Summary.csv"
        if summary_csv.exists():
            out.write(f"--- STARsolo Summary ({sub}) ---\\n")
            with open(summary_csv) as sf:
                for line in sf:
                    out.write(f"  {line.strip()}\\n")
            out.write("\\n")

    # Parse barcodes for total cell count
    if barcodes_file:
        opener = gzip.open if str(barcodes_file).endswith('.gz') else open
        with opener(barcodes_file, 'rt') as bf:
            barcodes = [l.strip() for l in bf if l.strip()]
        total_cells = len(barcodes)
        out.write(f"Total barcodes (cells): {total_cells}\\n")
    else:
        total_cells = 0
        out.write("Total barcodes (cells): N/A (no barcodes file found)\\n")

    # Parse matrix for gene-per-cell stats
    if matrix_file:
        opener = gzip.open if str(matrix_file).endswith('.gz') else open
        genes_per_cell = {}
        with opener(matrix_file, 'rt') as mf:
            header_done = False
            for line in mf:
                line = line.strip()
                if line.startswith('%'):
                    continue
                if not header_done:
                    header_done = True  # skip dimension line
                    continue
                parts = line.split()
                if len(parts) >= 3:
                    cell_idx = int(parts[1])
                    genes_per_cell[cell_idx] = genes_per_cell.get(cell_idx, 0) + 1

        if genes_per_cell:
            counts = sorted(genes_per_cell.values())
            n = len(counts)
            median_genes = counts[n // 2]
            mean_genes = sum(counts) / n
            out.write(f"Cells with data in matrix: {n}\\n")
            out.write(f"Median genes per cell: {median_genes}\\n")
            out.write(f"Mean genes per cell: {mean_genes:.1f}\\n")
            out.write(f"Min genes per cell: {counts[0]}\\n")
            out.write(f"Max genes per cell: {counts[-1]}\\n")
        else:
            out.write("Matrix: empty or could not parse\\n")
    else:
        out.write("Matrix file: not found\\n")

    # Parse features for total gene count
    if features_file:
        opener = gzip.open if str(features_file).endswith('.gz') else open
        with opener(features_file, 'rt') as ff:
            total_genes = sum(1 for l in ff if l.strip())
        out.write(f"Total genes in reference: {total_genes}\\n")

    out.write("\\n=== End of Summary ===\\n")
    out.close()

    # Also print to stdout
    with open(f"{sample}_summary.txt") as f:
        print(f.read())
    """
}

// ── Workflow ──────────────────────────────────────────────────────────────────
workflow {
    if (!params.reads)     { error "Missing --reads parameter" }
    if (!params.reference) { error "Missing --reference parameter" }
    if (!params.gtf)       { error "Missing --gtf parameter" }
    if (!params.outdir)    { error "Missing --outdir parameter" }

    log.info """
    ============================================
     SINGLE-CELL RNA-SEQ PIPELINE
    ============================================
     reads      : ${params.reads}
     reference  : ${params.reference}
     gtf        : ${params.gtf}
     outdir     : ${params.outdir}
     project    : ${params.project_name}
     whitelist  : ${params.whitelist ?: 'bundled 3M-february-2018.txt'}
    ============================================
    """.stripIndent()

    // Channel for paired reads: expects *_R{1,2}.fastq.gz
    Channel
        .fromFilePairs(params.reads, checkIfExists: true)
        .set { read_pairs_ch }

    ch_fasta = file(params.reference, checkIfExists: true)
    ch_gtf   = file(params.gtf, checkIfExists: true)

    // Whitelist: use provided file or fall back to bundled 10x v3 whitelist
    if (params.whitelist) {
        ch_whitelist = file(params.whitelist, checkIfExists: true)
    } else {
        ch_whitelist = file("/usr/local/share/STAR/3CB_UMI_Complex/3M-february-2018.txt")
    }

    // Run QC on raw reads
    FASTQC(read_pairs_ch)

    // Either use existing STAR index or build it
    if (params.star_index && file(params.star_index).exists()) {
        ch_star_index = Channel.fromPath(params.star_index).first()
    } else {
        ch_star_index = STAR_INDEX(ch_fasta, ch_gtf)
    }

    // STARsolo alignment + barcode demux
    STARSOLO(read_pairs_ch, ch_star_index, ch_gtf, ch_whitelist)

    // Summarize results
    SUMMARIZE(STARSOLO.out.solo_out)
}
