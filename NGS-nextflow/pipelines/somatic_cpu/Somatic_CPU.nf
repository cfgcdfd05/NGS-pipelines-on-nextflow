#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

params.cohort_name = "cohort"
params.reads       = null
params.reference   = null
params.outdir      = null



process FASTQC {

    tag "$sample_id"

    publishDir "${params.outdir}/fastqc", mode: 'copy'

    container 'biocontainers/fastqc:v0.11.9_cv8'

    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple val(sample_id), path(reads)

    output:
    tuple val(sample_id), path("*.html"), emit: html
    tuple val(sample_id), path("*.zip"), emit: zip

    script:
    """
    echo "INFO: Running FastQC for ${sample_id}"

    fastqc \
        ${reads[0]} \
        ${reads[1]} \
        --threads ${task.cpus} \
        --outdir .
    """
}

process FASTP {
    tag "$sample_id"
    publishDir "${params.outdir}/fastp", mode: 'copy'
    container 'quay.io/biocontainers/fastp:0.23.4--h5f740d0_0'
    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple val(sample_id), path(reads)

    output:
    tuple val(sample_id), path("${sample_id}_trimmed_R*.fastq.gz"), emit: trimmed_reads
    tuple val(sample_id), path("${sample_id}_fastp.json"), path("${sample_id}_fastp.html"), emit: reports

    script:
    """
    echo "INFO: Running fastp for ${sample_id}"
    fastp \\
        -i ${reads[0]} -I ${reads[1]} \\
        -o ${sample_id}_trimmed_R1.fastq.gz -O ${sample_id}_trimmed_R2.fastq.gz \\
        --thread ${task.cpus} \\
        --json ${sample_id}_fastp.json \\
        --html ${sample_id}_fastp.html
    """
}

process BWA_ALIGN {

    tag "$sample_id"

    publishDir "${params.outdir}/bam", mode: 'copy'

    container 'biocontainers/bwa:v0.7.17_cv1'

    errorStrategy 'retry'
    maxRetries 1

    input:
    tuple val(sample_id), path(reads)

    path reference
    path ref_fai
    path ref_dict

    path ref_bwt
    path ref_ann
    path ref_amb
    path ref_pac
    path ref_sa


    output:
    tuple val(sample_id), path("${sample_id}.sam"), emit: sam

    script:

    def rg = "@RG\\tID:${sample_id}\\tSM:${sample_id}\\tPL:ILLUMINA\\tLB:lib1\\tPU:unit1"

    """
    echo "INFO: BWA alignment for ${sample_id}"

    bwa mem \
        -t ${task.cpus} \
        -R '${rg}' \
        ${reference} \
        ${reads[0]} \
        ${reads[1]} \
        > ${sample_id}.sam

    [ -s "${sample_id}.sam" ] || {
        echo "ERROR: empty SAM"
        exit 1
    }
    """
}

process SORT_BAM {

    tag "$sample_id"

    publishDir "${params.outdir}/bam", mode: 'copy'

    container 'broadinstitute/gatk:4.6.2.0'

    errorStrategy 'retry'
    maxRetries 1

    input:
    tuple val(sample_id), path(sam)

    output:
    tuple val(sample_id), path("${sample_id}.sorted.bam"), emit: sorted_bam

    script:
    def mem_per_thread = Math.max( (task.memory.toMega() * 0.8 / task.cpus).intValue(), 500 )

    """
    echo "INFO: Sorting BAM for ${sample_id}"

    samtools sort \
        -@ ${task.cpus} \
        -m ${mem_per_thread}M \
        -T /tmp/${sample_id}_tmp \
        -o ${sample_id}.sorted.bam \
        ${sam}

    [ -s "${sample_id}.sorted.bam" ] || {
        echo "ERROR: empty sorted BAM"
        exit 1
    }

    # Clean up temp files explicitly
    rm -rf /tmp/${sample_id}_tmp*
    """
}


process MARK_DUPLICATES {

    tag "$sample_id"

    publishDir "${params.outdir}/bam", mode: 'copy'

    container 'broadinstitute/gatk:4.6.2.0'

    errorStrategy 'retry'
    maxRetries 1

    input:
    tuple val(sample_id), path(sorted_bam)

    output:
    tuple val(sample_id),
          path("${sample_id}.bam"),
          path("${sample_id}.metrics.txt"),
          emit: bam_metrics

    script:
    """
    echo "INFO: MarkDuplicates for ${sample_id}"

    gatk MarkDuplicates \
        -I ${sorted_bam} \
        -O ${sample_id}.bam \
        -M ${sample_id}.metrics.txt \
        --TMP_DIR /tmp

    [ -s "${sample_id}.bam" ] || {
        echo "ERROR: empty BAM"
        exit 1
    }

    # Clean up temp files explicitly
    rm -rf /tmp/*
    """
}


process INDEX_BAM {

    tag "$sample_id"

    publishDir "${params.outdir}/bam", mode: 'copy'

    container 'broadinstitute/gatk:4.6.2.0'

    errorStrategy 'retry'
    maxRetries 1

    input:
    tuple val(sample_id), path(bam), path(metrics)

    output:
    tuple val(sample_id),
    path("${sample_id}.bam"),
    path("${sample_id}.bam.bai"),
    emit: bam_bai

    script:
    """
    echo "INFO: Indexing BAM for ${sample_id}"

    samtools index \
        -@ ${task.cpus} \
        ${bam}

    [ -s "${sample_id}.bam.bai" ] || {
        echo "ERROR: BAM index missing"
        exit 1
    }
    """
}

process MUTECT2 {

    tag "$sample_id"

    publishDir "${params.outdir}/vcf", mode: 'copy'

    container 'broadinstitute/gatk:4.6.2.0'

    errorStrategy 'retry'
    maxRetries 1

    input:
    tuple val(sample_id), path(bam), path(bai)

    path reference
    path ref_fai
    path ref_dict

    output:
    tuple val(sample_id),
    path("${sample_id}.mutect2.vcf.gz"),
    path("${sample_id}.mutect2.vcf.gz.tbi"),
    path("${sample_id}.mutect2.vcf.gz.stats"),
    emit: raw_vcf

    script:

    def java_mem = Math.max(task.memory.toGiga().intValue()-2, 1)

    """
    echo "INFO: Mutect2 for ${sample_id}"

    gatk \
        --java-options "-Xmx${java_mem}g" \
        Mutect2 \
        --native-pair-hmm-threads ${task.cpus} \
        -R ${reference} \
        -I ${bam} \
        -O ${sample_id}.mutect2.vcf.gz

    [ -s "${sample_id}.mutect2.vcf.gz" ] || {
        echo "ERROR: empty Mutect2 VCF"
        exit 1
    }
    """
}

process FILTER_MUTECT_CALLS {

    tag "$sample_id"

    publishDir "${params.outdir}/vcf", mode: 'copy'

    container 'broadinstitute/gatk:4.6.2.0'

    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple val(sample_id), path(vcf), path(tbi), path(stats)

    path reference
    path ref_fai
    path ref_dict

    output:
    tuple val(sample_id),
    path("${sample_id}.filtered.vcf.gz"),
    path("${sample_id}.filtered.vcf.gz.tbi"),
    emit: filtered_vcf

    script:
    """
    echo "INFO: FilterMutectCalls for ${sample_id}"

    gatk FilterMutectCalls \
        -R ${reference} \
        -V ${vcf} \
        -O ${sample_id}.filtered.vcf.gz

    gatk IndexFeatureFile \
        -I ${sample_id}.filtered.vcf.gz

    [ -s "${sample_id}.filtered.vcf.gz" ] || {
        echo "ERROR: empty filtered VCF"
        exit 1
    }
    """
}

process PASS_VCF {

    tag "$sample_id"

    publishDir "${params.outdir}/vcf", mode: 'copy'

    container 'broadinstitute/gatk:4.6.2.0'

    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple val(sample_id), path(filtered_vcf), path(filtered_tbi)

    output:
    tuple val(sample_id),
    path("${sample_id}.pass.vcf.gz"),
    path("${sample_id}.pass.vcf.gz.csi"),
    emit: pass_vcf

    script:
    """
    echo "INFO: Extracting PASS variants for ${sample_id}"

    bcftools view \
        -f PASS \
        ${filtered_vcf} \
        -Oz \
        -o ${sample_id}.pass.vcf.gz

    bcftools index \
        ${sample_id}.pass.vcf.gz

    PASS_COUNT=\$(bcftools view -H ${sample_id}.pass.vcf.gz | wc -l)

    echo "INFO: PASS variants for ${sample_id} = \${PASS_COUNT}"
    """
}

workflow {

    if (!params.reads)
        error "MISSING PARAMETER: --reads is required"

    if (!params.reference)
        error "MISSING PARAMETER: --reference is required"

    if (!params.outdir)
        error "MISSING PARAMETER: --outdir is required"

    def ref = file(params.reference)
    def ref_fai = file("${params.reference}.fai")

    def ref_base = params.reference.toString().replaceAll(/\.fasta$/, "").replaceAll(/\.fa$/, "")

    def ref_dict = file("${ref_base}.dict")

    def ref_bwt = file("${ref_base}.bwt").exists() ? file("${ref_base}.bwt") : file("${params.reference}.bwt")
    def ref_ann = file("${ref_base}.ann").exists() ? file("${ref_base}.ann") : file("${params.reference}.ann")
    def ref_amb = file("${ref_base}.amb").exists() ? file("${ref_base}.amb") : file("${params.reference}.amb")
    def ref_pac = file("${ref_base}.pac").exists() ? file("${ref_base}.pac") : file("${params.reference}.pac")
    def ref_sa  = file("${ref_base}.sa").exists()  ? file("${ref_base}.sa")  : file("${params.reference}.sa")

    log.info """
    ============================================
     SOMATIC CPU VARIANT CALLING PIPELINE
    ============================================
     reads      : ${params.reads}
     reference  : ${params.reference}
     outdir     : ${params.outdir}
     cohort     : ${params.cohort_name}
    ============================================
    """.stripIndent()

    Channel
        .fromFilePairs(params.reads, checkIfExists: true)
        .set { read_pairs_ch }

    FASTQC(read_pairs_ch)
    FASTP(read_pairs_ch)

    BWA_ALIGN(
    FASTP.out.trimmed_reads,
    ref,
    ref_fai,
    ref_dict,
    ref_bwt,
    ref_ann,
    ref_amb,
    ref_pac,
    ref_sa
    )


    SORT_BAM(
        BWA_ALIGN.out.sam
    )

    MARK_DUPLICATES(
        SORT_BAM.out.sorted_bam
    )

    INDEX_BAM(
        MARK_DUPLICATES.out.bam_metrics
    )

    MUTECT2(
        INDEX_BAM.out.bam_bai,
        ref,
        ref_fai,
        ref_dict
    )

    FILTER_MUTECT_CALLS(
        MUTECT2.out.raw_vcf,
        ref,
        ref_fai,
        ref_dict
    )

    PASS_VCF(
        FILTER_MUTECT_CALLS.out.filtered_vcf
    )
}
