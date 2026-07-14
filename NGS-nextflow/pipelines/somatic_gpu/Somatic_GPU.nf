#!/usr/bin/env nextflow

/*
 * Somatic Variant Calling Pipeline — NVIDIA Parabricks (GPU-accelerated)
 * Steps: FastQC → fastp → fq2bam (GPU) → Mutect2 → FilterMutectCalls → PASS VCF
 */

nextflow.enable.dsl = 2

def getParabricksSpaceFix() {
    return '''
    mkdir -p /tmp/pb_fix
    cat << 'EOF_SITE' > /tmp/pb_fix/sitecustomize.py
import subprocess
import os

def _fix_cmd(cmd):
    if not isinstance(cmd, str):
        return cmd
    i = 0
    res = []
    n = len(cmd)
    while i < n:
        if cmd[i] == '/' and (i == 0 or cmd[i-1] in ' \\t=:('):
            best_j = -1
            j = i + 1
            while j <= n:
                candidate = cmd[i:j]
                valid = False
                if os.path.exists(candidate):
                    valid = True
                else:
                    parent = os.path.dirname(candidate)
                    base = os.path.basename(candidate)
                    if parent and os.path.exists(parent) and base and not any(c in base for c in ' \\t\\n|;&>\\"\\''):
                        valid = True
                if valid:
                    if j == n or cmd[j] in ' \\t\\n\\"\\'\\x00|;>':
                        if ' ' in candidate:
                            best_j = j
                j += 1
            if best_j != -1:
                path_str = cmd[i:best_j]
                res.append('\"' + path_str + '\"')
                i = best_j
                continue
        res.append(cmd[i])
        i += 1
    return ''.join(res)

_orig_popen = subprocess.Popen
_orig_run = subprocess.run

def _patched_popen(*args, **kwargs):
    if args and isinstance(args[0], str) and kwargs.get('shell', False):
        args = list(args)
        args[0] = _fix_cmd(args[0])
    elif 'args' in kwargs and isinstance(kwargs['args'], str) and kwargs.get('shell', False):
        kwargs['args'] = _fix_cmd(kwargs['args'])
    return _orig_popen(*args, **kwargs)

def _patched_run(*args, **kwargs):
    if args and isinstance(args[0], str) and kwargs.get('shell', False):
        args = list(args)
        args[0] = _fix_cmd(args[0])
    elif 'args' in kwargs and isinstance(kwargs['args'], str) and kwargs.get('shell', False):
        kwargs['args'] = _fix_cmd(kwargs['args'])
    return _orig_run(*args, **kwargs)

subprocess.Popen = _patched_popen
subprocess.run = _patched_run
EOF_SITE
    export PYTHONPATH=/tmp/pb_fix:${PYTHONPATH:-}
'''
}

// ── Parameters ───────────────────────────────────────────────────────────────
params.cohort_name      = "cohort"
params.reads            = null
params.reference        = null
params.outdir           = null
params.parabricks_image = "nvcr.io/nvidia/clara/clara-parabricks:4.4.0-1"
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

// ── Process 2: fastp (Trimming) ───────────────────────────────────────────────
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

// ── Process 3: fq2bam (GPU) ──────────────────────────────────────────────────
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
    def rg = "@RG\\\\tID:${sample_id}\\\\tSM:${sample_id}\\\\tPL:ILLUMINA\\\\tLB:lib1\\\\tPU:unit1"
    """
    ${env_override}
    ${getParabricksSpaceFix()}
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

// ── Process 4: Mutect2 (CPU — GATK) ──────────────────────────────────────────
process MUTECT2 {
    tag "$sample_id"
    publishDir "${params.outdir}/vcf", mode: 'copy'
    container 'broadinstitute/gatk:4.6.2.0'
    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple val(sample_id), path(bam), path(bai)
    path reference
    path ref_fai
    path ref_dict

    output:
    tuple val(sample_id), path("${sample_id}.raw.vcf"),     emit: raw_vcf
    tuple val(sample_id), path("${sample_id}.raw.vcf.stats"), emit: stats

    script:
    """
    echo "INFO: Mutect2 for ${sample_id}"

    gatk Mutect2 \\
        -R ${reference} \\
        -I ${bam} \\
        -O ${sample_id}.raw.vcf

    [ -s "${sample_id}.raw.vcf" ] || { echo "ERROR: empty raw VCF for ${sample_id}"; exit 1; }
    """
}

// ── Process 5: FilterMutectCalls ──────────────────────────────────────────────
process FILTER_MUTECT_CALLS {
    tag "$sample_id"
    publishDir "${params.outdir}/vcf", mode: 'copy'
    container 'broadinstitute/gatk:4.6.2.0'
    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple val(sample_id), path(raw_vcf)
    tuple val(sample_id_stats), path(stats)
    path reference
    path ref_fai
    path ref_dict

    output:
    tuple val(sample_id), path("${sample_id}.filtered.vcf"), emit: filtered_vcf

    script:
    """
    echo "INFO: FilterMutectCalls for ${sample_id}"

    gatk FilterMutectCalls \\
        -R ${reference} \\
        -V ${raw_vcf} \\
        --stats ${stats} \\
        -O ${sample_id}.filtered.vcf

    [ -s "${sample_id}.filtered.vcf" ] || { echo "ERROR: empty filtered VCF for ${sample_id}"; exit 1; }
    """
}

// ── Process 6: PASS VCF ──────────────────────────────────────────────────────
process PASS_VCF {
    tag "$sample_id"
    publishDir "${params.outdir}/vcf", mode: 'copy'
    container 'staphb/bcftools:1.20'
    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple val(sample_id), path(filtered_vcf)

    output:
    tuple val(sample_id), path("${sample_id}.pass.vcf"), emit: pass_vcf

    script:
    """
    bcftools view \\
        -f PASS \\
        ${filtered_vcf} \\
        > ${sample_id}.pass.vcf

    PASS_COUNT=\$(grep -vc "^#" ${sample_id}.pass.vcf || true)

    echo "INFO: PASS variants for ${sample_id} = \${PASS_COUNT}"
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
     SOMATIC GPU VARIANT CALLING PIPELINE
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
    // Prevent Mutect2 from starting until ALL FQ2BAM tasks are finished.
    // This prevents cross-process GPU memory concurrency which would crash
    // systems with limited RAM even with maxForks limits.
    barrier_ch = FQ2BAM.out.bam_bai
        .toList()
        .flatMap { it }

    MUTECT2             ( barrier_ch, ref, ref_fai, ref_dict )
    FILTER_MUTECT_CALLS ( MUTECT2.out.raw_vcf, MUTECT2.out.stats, ref, ref_fai, ref_dict )
    PASS_VCF            ( FILTER_MUTECT_CALLS.out.filtered_vcf )
}
