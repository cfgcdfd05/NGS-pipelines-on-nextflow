#!/usr/bin/env nextflow

/*
 * RNA-seq Pipeline — CPU-based Alignment + Quantification
 * Steps: FastQC → fastp (trimming) → STAR (Alignment) → featureCounts (Quantification)
 */

nextflow.enable.dsl = 2

// ── Parameters ───────────────────────────────────────────────────────────────
params.project_name     = "rnaseq_project"
params.reads            = null
params.reference        = null
params.gtf              = null
params.outdir           = null
params.star_index       = null

params.fastqc_image     = "biocontainers/fastqc:v0.11.9_cv8"
params.fastp_image      = "quay.io/biocontainers/fastp:0.23.4--h5f740d0_0"
params.star_image       = "quay.io/biocontainers/star:2.7.11a--h0033a41_0"
params.subread_image    = "quay.io/biocontainers/subread:2.0.6--he4a0461_0"

// ── Process 1: FastQC ─────────────────────────────────────────────────────────
process FASTQC {
    tag "${meta.id}"
    publishDir "${params.outdir}/fastqc", mode: 'copy'
    container params.fastqc_image
    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple val(meta), path(reads)

    output:
    tuple val(meta), path("*.html"), emit: html
    tuple val(meta), path("*.zip"),  emit: zip

    script:
    """
    echo "INFO: Running FastQC for ${meta.id}"
    fastqc ${reads[0]} ${reads[1]} \
        --threads ${task.cpus} \
        --outdir .
    """
}

// ── Process 2: fastp (Trimming) ───────────────────────────────────────────────
process FASTP {
    tag "${meta.id}"
    publishDir "${params.outdir}/fastp", mode: 'copy'
    container params.fastp_image
    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple val(meta), path(reads)

    output:
    tuple val(meta), path("${meta.id}_trimmed_R1.fastq.gz"), path("${meta.id}_trimmed_R2.fastq.gz"), emit: trimmed_reads
    tuple val(meta), path("${meta.id}_fastp.json"), path("${meta.id}_fastp.html"), emit: reports

    script:
    """
    echo "INFO: Running fastp for ${meta.id}"
    fastp \
        -i ${reads[0]} -I ${reads[1]} \
        -o ${meta.id}_trimmed_R1.fastq.gz -O ${meta.id}_trimmed_R2.fastq.gz \
        --thread ${task.cpus} \
        --json ${meta.id}_fastp.json \
        --html ${meta.id}_fastp.html
    """
}

// ── Process 3: STAR Indexing (Optional) ───────────────────────────────────────
process STAR_INDEX {
    tag "STAR_index"
    publishDir "${params.outdir}", mode: 'copy'
    container params.star_image

    input:
    path fasta
    path gtf

    output:
    path "star_index", emit: index

    script:
    """
    mkdir -p star_index
    STAR --runMode genomeGenerate \\
         --genomeDir star_index \\
         --genomeFastaFiles ${fasta} \\
         --sjdbGTFfile ${gtf} \\
         --runThreadN ${task.cpus} \\
         --genomeSAindexNbases 14
    
    # Fix for Parabricks: remove unrecognized parameters from genomeParameters.txt
    sed -i '/genomeType/d' star_index/genomeParameters.txt
    sed -i '/genomeTransform/d' star_index/genomeParameters.txt
    sed -i 's/2.7.4a/2.7.1a/g' star_index/genomeParameters.txt
    """
}

// ── Process 4: STAR Alignment ─────────────────────────────────────────────────
process STAR_ALIGN {
    tag "${meta.id}"
    publishDir "${params.outdir}/star_bam", mode: 'copy'
    container params.star_image
    errorStrategy 'retry'
    maxRetries 1

    input:
    tuple val(meta), path(r1), path(r2)
    path index
    path gtf

    output:
    tuple val(meta), path("${meta.id}Aligned.sortedByCoord.out.bam"), emit: bam
    tuple val(meta), path("${meta.id}Log.final.out"), emit: log

    script:
    """
    echo "INFO: STAR alignment for ${meta.id}"
    
    STAR --runMode alignReads \
         --genomeDir ${index} \
         --readFilesIn ${r1} ${r2} \
         --readFilesCommand zcat \
         --outFileNamePrefix ${meta.id} \
         --outSAMtype BAM SortedByCoordinate \
         --runThreadN ${task.cpus} \
         --sjdbGTFfile ${gtf} \
         --outSAMunmapped Within \
         --outSAMattributes Standard
    """
}

// ── Process 5: featureCounts ──────────────────────────────────────────────────
process FEATURE_COUNTS {
    tag "${meta.id}"
    publishDir "${params.outdir}/counts", mode: 'copy'
    container params.subread_image

    input:
    tuple val(meta), path(bam)
    path gtf

    output:
    tuple val(meta), path("${meta.id}_featureCounts.txt"), emit: counts
    tuple val(meta), path("${meta.id}_featureCounts.txt.summary"), emit: summary

    script:
    """
    echo "INFO: Running featureCounts for ${meta.id}"
    
    if ! featureCounts \\
        -T ${task.cpus} \\
        -a ${gtf} \\
        -o ${meta.id}_featureCounts.txt \\
        ${bam}; then
        echo "Single-end counting failed, falling back to paired-end (-p) counting..."
        featureCounts \\
            -p \\
            -T ${task.cpus} \\
            -a ${gtf} \\
            -o ${meta.id}_featureCounts.txt \\
            ${bam}
    fi
    """
}



// ── Workflow ──────────────────────────────────────────────────────────────────
workflow {
    if (!params.reads) { error "Missing --reads parameter" }
    if (!params.reference) { error "Missing --reference parameter" }
    if (!params.gtf) { error "Missing --gtf parameter" }

    ch_reads = Channel.fromFilePairs(params.reads, checkIfExists: true)
        .map { name, reads -> 
            def meta = [id: name]
            return [meta, reads]
        }
    
    ch_fasta = file(params.reference, checkIfExists: true)
    ch_gtf = file(params.gtf, checkIfExists: true)

    // Run QC and Trimming
    FASTQC(ch_reads)
    FASTP(ch_reads)

    // Either use existing index or build it
    if (params.star_index && file(params.star_index).exists()) {
        ch_star_index = Channel.fromPath(params.star_index).first()
    } else {
        ch_star_index = STAR_INDEX(ch_fasta, ch_gtf)
    }

    // Align and Quantify
    STAR_ALIGN(FASTP.out.trimmed_reads, ch_star_index, ch_gtf)
    FEATURE_COUNTS(STAR_ALIGN.out.bam, ch_gtf)
    
    // Generate Publication Chart
}
