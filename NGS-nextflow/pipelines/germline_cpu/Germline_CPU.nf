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

process HAPLOTYPE_CALLER {

    tag "$sample_id"

    publishDir "${params.outdir}/gvcf", mode: 'copy'

    container 'broadinstitute/gatk:4.6.2.0'

    errorStrategy 'retry'
    maxRetries 1

    input:
    tuple val(sample_id), path(bam), path(bai)

    path reference
    path ref_fai
    path ref_dict

    output:
    tuple val(sample_id), path("${sample_id}.g.vcf.gz"), path("${sample_id}.g.vcf.gz.tbi"), emit: gvcf

    script:

    def java_mem = Math.max(task.memory.toGiga().intValue()-2, 1)
    
    """
    echo "INFO: HaplotypeCaller for ${sample_id}"

    gatk \
        --java-options "-Xmx${java_mem}g" \
        HaplotypeCaller \
        --native-pair-hmm-threads ${task.cpus} \
        -R ${reference} \
        -I ${bam} \
        -O ${sample_id}.g.vcf.gz \
        -ERC GVCF

    gatk IndexFeatureFile \
        -I ${sample_id}.g.vcf.gz
    
    [ -s "${sample_id}.g.vcf.gz" ] || {
        echo "ERROR: empty GVCF"
        exit 1
    }
    """
}

process GENOTYPE_GVCFS {

    publishDir "${params.outdir}/vcf", mode: 'copy'

    container 'broadinstitute/gatk:4.6.2.0'

    errorStrategy 'retry'
    maxRetries 1

    input:
    path gvcfs
    path tbis

    path reference
    path ref_fai
    path ref_dict

    output:
    tuple path("${params.cohort_name}.vcf.gz"), path("${params.cohort_name}.vcf.gz.tbi"), emit: cohort_vcf

    script:

    def java_mem = Math.max(task.memory.toGiga().intValue()-2, 1)

    def gvcf_args = (gvcfs instanceof List
        ? gvcfs.collect { "-V ${it}" }
        : [ "-V ${gvcfs}" ]
    ).join(" \\\n        ")

    """
    echo "INFO: Joint genotyping"

    gatk \
        --java-options "-Xmx${java_mem}g" \
        CombineGVCFs \
        -R ${reference} \
        ${gvcf_args} \
        -O combined.g.vcf.gz

    gatk \
        --java-options "-Xmx${java_mem}g" \
        GenotypeGVCFs \
        -R ${reference} \
        -V combined.g.vcf.gz \
        -O ${params.cohort_name}.vcf.gz
    
    gatk IndexFeatureFile \
        -I ${params.cohort_name}.vcf.gz

    [ -s "${params.cohort_name}.vcf.gz" ] || {
        echo "ERROR: empty VCF"
        exit 1
    }
    """
}

process VARIANT_FILTRATION {

    publishDir "${params.outdir}/vcf", mode: 'copy'

    container 'broadinstitute/gatk:4.6.2.0'

    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple path(vcf), path(vcf_tbi)
    path reference
    path ref_fai
    path ref_dict

    output:
    tuple path("${params.cohort_name}.filtered.vcf.gz"),
    path("${params.cohort_name}.filtered.vcf.gz.tbi"),
    emit: filtered_vcf

    script:
    """
    echo "INFO: VariantFiltration"

    gatk VariantFiltration \
        -R ${reference} \
        -V ${vcf} \
        -O ${params.cohort_name}.filtered.vcf.gz \
        --filter-expression "QD < 2.0" \
        --filter-name "LowQD" \
        --filter-expression "FS > 60.0" \
        --filter-name "StrandBias" \
        --filter-expression "MQ < 40.0" \
        --filter-name "LowMQ"

    gatk IndexFeatureFile \
        -I ${params.cohort_name}.filtered.vcf.gz

    [ -s "${params.cohort_name}.filtered.vcf.gz" ] || {
        echo "ERROR: empty filtered VCF"
        exit 1
    }
    """
}

process PASS_VCF {

    publishDir "${params.outdir}/vcf", mode: 'copy'

    container 'staphb/bcftools:1.20'

    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple path(filtered_vcf), path(filtered_tbi)

    output:
    tuple path("${params.cohort_name}.pass.vcf.gz"),
    path("${params.cohort_name}.pass.vcf.gz.csi"),
    emit: pass_vcf

    script:
    """
    echo "INFO: Extracting PASS variants"

    bcftools view \
        -f PASS \
        ${filtered_vcf} \
        -Oz \
        -o ${params.cohort_name}.pass.vcf.gz

    bcftools index \
        ${params.cohort_name}.pass.vcf.gz

    PASS_COUNT=\$(bcftools view -H ${params.cohort_name}.pass.vcf.gz | wc -l)

    echo "INFO: PASS variants = \${PASS_COUNT}"
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
     GERMLINE CPU VARIANT CALLING PIPELINE
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

    HAPLOTYPE_CALLER(
        INDEX_BAM.out.bam_bai,
        ref,
        ref_fai,
        ref_dict
    )

    all_gvcfs_ch = HAPLOTYPE_CALLER.out.gvcf
        .map { sample_id, gvcf, tbi -> gvcf }
        .collect()
        
    all_tbis_ch = HAPLOTYPE_CALLER.out.gvcf
        .map { sample_id, gvcf, tbi -> tbi }
        .collect()

    GENOTYPE_GVCFS(
        all_gvcfs_ch,
        all_tbis_ch,
        ref,
        ref_fai,
        ref_dict
    )

    VARIANT_FILTRATION(
        GENOTYPE_GVCFS.out.cohort_vcf,
        ref,
        ref_fai,
        ref_dict
    )

    PASS_VCF(
        VARIANT_FILTRATION.out.filtered_vcf
    )
}