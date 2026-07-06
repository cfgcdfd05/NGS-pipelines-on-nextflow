#!/usr/bin/env nextflow

/*
 * Germline Variant Calling Pipeline — NVIDIA Parabricks (GPU-accelerated)
 * Supports single-sample and cohort calling
 * Steps: FastQC → fq2bam → HaplotypeCaller (GVCF) → GenotypeGVCFs → Filtered VCF → PASS VCF
 */

nextflow.enable.dsl = 2

// ── Parameters ───────────────────────────────────────────────────────────────
// No default paths. --reads, --reference and --outdir are REQUIRED and must
// be supplied relative to the current working directory (run_pipeline.sh
// prompts for these and passes them in). This keeps the pipeline portable —
// no machine-specific paths are baked in anywhere.
params.cohort_name      = "cohort"
params.reads            = null
params.reference        = null
params.outdir           = null
params.parabricks_image = "nvcr.io/nvidia/clara/clara-parabricks:4.7.0-1"
params.low_memory       = false
params.num_gpus         = 1

// ── Process 1: FastQC ─────────────────────────────────────────────────────────
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
    tuple val(sample_id), path("*.zip"),  emit: zip

    script:
    """
    echo "INFO: Running FastQC for ${sample_id}"
    fastqc ${reads[0]} ${reads[1]} \\
        --threads ${task.cpus} \\
        --outdir .
    """
}

// ── Process 1.5: fastp (Trimming) ─────────────────────────────────────────────
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

// ── Process 2: fq2bam (GPU) ───────────────────────────────────────────────────
process FQ2BAM {
    tag "$sample_id"
    publishDir "${params.outdir}/bam", mode: 'copy'
    container params.parabricks_image
    accelerator 1, type: 'nvidia.com/gpu'
    maxForks (params.num_gpus as int)
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
    tuple val(sample_id),
          path("${sample_id}.bam"),
          path("${sample_id}.bam.bai"), emit: bam_bai

    script:
    def env_override = "export LD_LIBRARY_PATH=/usr/local/nvidia/lib:/usr/local/nvidia/lib64"
    def rg = "@RG\\tID:${sample_id}\\tSM:${sample_id}\\tPL:ILLUMINA\\tLB:lib1\\tPU:unit1"
    """
    ${env_override}
    echo "INFO: fq2bam for ${sample_id}"

    pbrun fq2bam \\
        --ref ${reference} \\
        --in-fq ${reads[0]} ${reads[1]} "${rg}" \\
        --out-bam ${sample_id}.bam \\
        --num-gpus 1 \\
        ${params.low_memory ? '--low-memory' : ''}

    [ -s "${sample_id}.bam" ] || { echo "ERROR: empty BAM for ${sample_id}"; exit 1; }
    """
}

// ── Process 3: HaplotypeCaller (GPU) — per-sample GVCF ───────────────────────
process HAPLOTYPE_CALLER {
    tag "$sample_id"
    publishDir "${params.outdir}/gvcf", mode: 'copy'
    container params.parabricks_image
    accelerator 1, type: 'nvidia.com/gpu'
    maxForks (params.num_gpus as int)
    errorStrategy 'retry'
    maxRetries 1

    input:
    tuple val(sample_id), path(bam), path(bai)
    path reference
    path ref_fai
    path ref_dict

    output:
    tuple val(sample_id), path("${sample_id}.g.vcf"), emit: gvcf

    script:
    def env_override = "export LD_LIBRARY_PATH=/usr/local/nvidia/lib:/usr/local/nvidia/lib64"
    """
    ${env_override}
    echo "INFO: HaplotypeCaller for ${sample_id}"

    pbrun haplotypecaller \\
        --ref ${reference} \\
        --in-bam ${bam} \\
        --out-variants ${sample_id}.g.vcf \\
        --gvcf \\
        --num-gpus 1

    [ -s "${sample_id}.g.vcf" ] || { echo "ERROR: empty GVCF for ${sample_id}"; exit 1; }
    """
}

// ── Process 4: GenotypeGVCFs (GPU) ───────────────────────────────────────────
process GENOTYPE_GVCFS {
    publishDir "${params.outdir}/vcf", mode: 'copy'
    container params.parabricks_image
    errorStrategy 'retry'
    maxRetries 1

    input:
    path gvcfs
    path reference
    path ref_fai
    path ref_dict

    output:
    path "${params.cohort_name}.vcf", emit: cohort_vcf

    script:
    def gvcf_args = (gvcfs instanceof List
        ? gvcfs.collect { "--in-gvcf ${it}" }
        : [ "--in-gvcf ${gvcfs}" ]
    ).join(" \\\n        ")
    """
    echo "INFO: GenotypeGVCFs — joint genotyping"

    pbrun genotypegvcf \\
        --ref ${reference} \\
        ${gvcf_args} \\
        --out-vcf ${params.cohort_name}.vcf

    [ -s "${params.cohort_name}.vcf" ] || { echo "ERROR: empty cohort VCF"; exit 1; }
    """
}

// ── Process 5: Variant Filtration ─────────────────────────────────────────────
process VARIANT_FILTRATION {

    publishDir "${params.outdir}/vcf", mode: 'copy'

    container 'broadinstitute/gatk:4.6.2.0'

    errorStrategy 'retry'
    maxRetries 2

    input:
    path vcf
    path reference
    path ref_fai
    path ref_dict

    output:
    path "${params.cohort_name}.filtered.vcf", emit: filtered_vcf

    script:
    """
    gatk VariantFiltration \
        -R ${reference} \
        -V ${vcf} \
        -O ${params.cohort_name}.filtered.vcf \
        --filter-expression "QD < 2.0" \
        --filter-name "LowQD" \
        --filter-expression "FS > 60.0" \
        --filter-name "StrandBias" \
        --filter-expression "MQ < 40.0" \
        --filter-name "LowMQ"

    [ -s "${params.cohort_name}.filtered.vcf" ] || {
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
    path filtered_vcf

    output:
    path "${params.cohort_name}.pass.vcf", emit: pass_vcf

    script:
    """
    bcftools view \
        -f PASS \
        ${filtered_vcf} \
        > ${params.cohort_name}.pass.vcf

    PASS_COUNT=\$(grep -vc "^#" ${params.cohort_name}.pass.vcf || true)

    echo "INFO: PASS variants = \${PASS_COUNT}"
    """
}




// ── Workflow ──────────────────────────────────────────────────────────────────
workflow {

    if (!params.reads)
        error "MISSING PARAMETER: --reads '<path>/*_R{1,2}.fastq.gz' is required"
    if (!params.reference)
        error "MISSING PARAMETER: --reference '<path>/reference.fasta' is required"
    if (!params.outdir)
        error "MISSING PARAMETER: --outdir '<path>' is required"

    // FIX: Validation now inside workflow block — DSL2 forbids top-level statements
    def ref      = file(params.reference)
    def ref_fai  = file("${params.reference}.fai")
    def ref_base = params.reference.toString().replaceAll(/\.fasta$/, "").replaceAll(/\.fa$/, "")

    def ref_dict = file("${ref_base}.dict")

    def ref_bwt = file("${ref_base}.bwt").exists() ? file("${ref_base}.bwt") : file("${params.reference}.bwt")
    def ref_ann = file("${ref_base}.ann").exists() ? file("${ref_base}.ann") : file("${params.reference}.ann")
    def ref_amb = file("${ref_base}.amb").exists() ? file("${ref_base}.amb") : file("${params.reference}.amb")
    def ref_pac = file("${ref_base}.pac").exists() ? file("${ref_base}.pac") : file("${params.reference}.pac")
    def ref_sa  = file("${ref_base}.sa").exists()  ? file("${ref_base}.sa")  : file("${params.reference}.sa")

    log.info """
    ============================================
     GERMLINE VARIANT CALLING PIPELINE
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

    // Per-sample parallel steps
    FASTQC          ( read_pairs_ch )
    FASTP           ( read_pairs_ch )
    FQ2BAM          ( FASTP.out.trimmed_reads, ref, ref_fai, ref_dict, ref_bwt, ref_ann, ref_amb, ref_pac, ref_sa )

    // STRICT EXECUTION BARRIER:
    // Prevent HAPLOTYPE_CALLER from starting until ALL FQ2BAM tasks are finished.
    // This prevents cross-process GPU memory concurrency (e.g. sample1 HC running while sample2 FQ2BAM runs),
    // which would crash systems with <100GB RAM even with maxForks limits.
    barrier_ch = FQ2BAM.out.bam_bai
        .toList()
        .flatMap { it }

    HAPLOTYPE_CALLER( barrier_ch, ref, ref_fai, ref_dict )

    // Wait for ALL GVCFs before joint genotyping
    all_gvcfs_ch = HAPLOTYPE_CALLER.out.gvcf
        .map    { sample_id, gvcf -> gvcf }
        .collect()

    // FIX: GENOTYPE_GVCFS was never invoked — added the missing call
    GENOTYPE_GVCFS( all_gvcfs_ch, ref, ref_fai, ref_dict )

   VARIANT_FILTRATION(GENOTYPE_GVCFS.out.cohort_vcf,ref,ref_fai,ref_dict)
    PASS_VCF( VARIANT_FILTRATION.out.filtered_vcf )
}
