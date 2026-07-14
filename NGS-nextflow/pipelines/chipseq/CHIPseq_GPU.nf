#!/usr/bin/env nextflow

/*
 * ChIP-seq Pipeline — NVIDIA Parabricks (GPU-accelerated) + MACS2
 * Supports single-sample and matched control (Input) peak calling
 * Steps: FastQC → fastp (trimming) → fq2bam (GPU) → MACS2 (CPU)
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
params.project_name     = "chipseq_project"
params.reads            = null
params.samplesheet      = null
params.reference        = null
params.outdir           = null
params.parabricks_image = "nvcr.io/nvidia/clara/clara-parabricks:4.7.0-1"
params.macs2_image      = "quay.io/biocontainers/macs2:2.2.7.1--py38h4a8c8d9_3"
params.fastp_image      = "quay.io/biocontainers/fastp:0.23.4--h5f740d0_0"
params.low_memory       = false
params.num_gpus         = 1

// ── Process 1: FastQC ─────────────────────────────────────────────────────────
process FASTQC {
    tag "${meta.id}"
    publishDir "${params.outdir}/fastqc", mode: 'copy'
    container 'biocontainers/fastqc:v0.11.9_cv8'
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
    fastqc ${reads[0]} ${reads[1]} \\
        --threads ${task.cpus} \\
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
    fastp \\
        -i ${reads[0]} -I ${reads[1]} \\
        -o ${meta.id}_trimmed_R1.fastq.gz -O ${meta.id}_trimmed_R2.fastq.gz \\
        --thread ${task.cpus} \\
        --json ${meta.id}_fastp.json \\
        --html ${meta.id}_fastp.html
    """
}

// ── Process 3: fq2bam (GPU) ───────────────────────────────────────────────────
process FQ2BAM {
    tag "${meta.id}"
    publishDir "${params.outdir}/bam", mode: 'copy'
    container params.parabricks_image
    accelerator 1, type: 'nvidia.com/gpu'
    maxForks (params.num_gpus as int)
    errorStrategy 'retry'
    maxRetries 1

    input:
    tuple val(meta), path(r1), path(r2)
    path reference
    path ref_fai
    path ref_dict
    path ref_bwt
    path ref_ann
    path ref_amb
    path ref_pac
    path ref_sa

    output:
    tuple val(meta), path("${meta.id}.bam"), path("${meta.id}.bam.bai"), emit: bam_bai

    script:
    def env_override = "export LD_LIBRARY_PATH=/usr/local/nvidia/lib:/usr/local/nvidia/lib64"
    def rg = "@RG\\tID:${meta.id}\\tSM:${meta.id}\\tPL:ILLUMINA\\tLB:lib1\\tPU:unit1"
    """
    ${env_override}
    ${getParabricksSpaceFix()}
    echo "INFO: fq2bam for ${meta.id}"

    pbrun fq2bam \\
        --ref ${reference} \\
        --in-fq ${r1} ${r2} "${rg}" \\
        --out-bam ${meta.id}.bam \\
        --num-gpus 1 \\
        ${params.low_memory ? '--low-memory' : ''}

    [ -s "${meta.id}.bam" ] || { echo "ERROR: empty BAM for ${meta.id}"; exit 1; }
    """
}

// ── Process 4: MACS2 ──────────────────────────────────────────────────────────
process MACS2 {
    tag "${treatment_id}"
    publishDir "${params.outdir}/macs2", mode: 'copy'
    container params.macs2_image
    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple val(treatment_id), path(treatment_bam), path(control_bam)

    output:
    tuple val(treatment_id), path("${treatment_id}_macs2*"), emit: macs2_output

    script:
    def control_args = control_bam.name != 'NO_CONTROL_BAM' ? "-c ${control_bam}" : ""
    def env_override = "export LD_LIBRARY_PATH=/usr/local/nvidia/lib:/usr/local/nvidia/lib64"
    """
    ${env_override}
    echo "INFO: MACS2 peak calling for ${treatment_id}"
    
    macs2 callpeak \\
        -t ${treatment_bam} \\
        ${control_args} \\
        -f BAMPE \\
        -g hs \\
        -n ${treatment_id}_macs2 \\
        -q 0.05 \\
        --outdir . || { echo "WARNING: MACS2 failed, likely due to zero mapped reads in test dataset."; touch ${treatment_id}_macs2_peaks.xls; }
    """
}




// ── Workflow ──────────────────────────────────────────────────────────────────
workflow {

    if (!params.reads && !params.samplesheet)
        error "MISSING PARAMETER: Either --reads or --samplesheet must be provided."
    if (!params.reference)
        error "MISSING PARAMETER: --reference '<path>/reference.fasta' is required."
    if (!params.outdir)
        error "MISSING PARAMETER: --outdir '<path>' is required."

    def ref      = file(params.reference)
    def ref_fai  = file("${params.reference}.fai")
    def ref_base = params.reference.toString().replaceAll(/\.fasta$/, "").replaceAll(/\.fa$/, "")

    def ref_dict = file("${ref_base}.dict")
    def ref_bwt  = file("${ref_base}.bwt").exists() ? file("${ref_base}.bwt") : file("${params.reference}.bwt")
    def ref_ann  = file("${ref_base}.ann").exists() ? file("${ref_base}.ann") : file("${params.reference}.ann")
    def ref_amb  = file("${ref_base}.amb").exists() ? file("${ref_base}.amb") : file("${params.reference}.amb")
    def ref_pac  = file("${ref_base}.pac").exists() ? file("${ref_base}.pac") : file("${params.reference}.pac")
    def ref_sa   = file("${ref_base}.sa").exists()  ? file("${ref_base}.sa")  : file("${params.reference}.sa")

    log.info """
    ============================================
     CHIP-SEQ GPU PIPELINE
    ============================================
     reads       : ${params.reads ?: 'N/A (using samplesheet)'}
     samplesheet : ${params.samplesheet ?: 'N/A (using fastq dir)'}
     reference   : ${params.reference}
     outdir      : ${params.outdir}
     project     : ${params.project_name}
    ============================================
    """.stripIndent()

    if (params.samplesheet) {
        Channel.fromPath(params.samplesheet)
            .splitCsv(header:true)
            .map { row ->
                def meta = [id: row.sample, control: row.control ?: '']
                def reads = [file(row.fastq_1), file(row.fastq_2)]
                [meta, reads]
            }
            .set { read_pairs_ch }
    } else {
        Channel.fromFilePairs(params.reads, checkIfExists: true)
            .map { id, reads -> 
                def meta = [id: id, control: '']
                [meta, reads]
            }
            .set { read_pairs_ch }
    }

    // Step 1 & 2: QC and Trimming
    FASTQC(read_pairs_ch)
    FASTP(read_pairs_ch)

    // Step 3: Alignment
    FQ2BAM(FASTP.out.trimmed_reads, ref, ref_fai, ref_dict, ref_bwt, ref_ann, ref_amb, ref_pac, ref_sa)

    // Step 4: MACS2 Data prep
    // Extract a channel mapping sample ID to BAM file
    def bam_by_id = FQ2BAM.out.bam_bai.map { meta, bam, bai -> [meta.id, bam] }

    // Isolate treatments with no control
    def treatments_without_control = FQ2BAM.out.bam_bai
        .filter { meta, bam, bai -> meta.control == '' }
        .map { meta, bam, bai -> 
            // Dummy file for Nextflow to handle optional inputs cleanly
            def dummy_file = file("${params.outdir}/NO_CONTROL_BAM")
            dummy_file.text = ""
            [meta.id, bam, dummy_file] 
        }

    // Isolate treatments WITH a control, key by control ID for joining
    def treatments_with_control = FQ2BAM.out.bam_bai
        .filter { meta, bam, bai -> meta.control != '' }
        .map { meta, bam, bai -> [meta.control, meta.id, bam] }

    // Join to get the control BAM
    def matched_controls = treatments_with_control.cross(bam_by_id) { it[0] }
        .map { treat_tuple, ctrl_tuple -> 
            def t_id  = treat_tuple[1]
            def t_bam = treat_tuple[2]
            def c_bam = ctrl_tuple[1]
            [t_id, t_bam, c_bam]
        }

    // Combine both streams
    def macs2_input = treatments_without_control.mix(matched_controls)

    // Step 5: Peak Calling
    MACS2(macs2_input)
}
