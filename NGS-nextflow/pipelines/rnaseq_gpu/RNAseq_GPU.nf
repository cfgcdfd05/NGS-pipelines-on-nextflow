#!/usr/bin/env nextflow

/*
 * RNA-seq Pipeline — GPU-accelerated Alignment + Quantification
 * Steps: FastQC (CPU) → fastp (CPU) → Parabricks rna_fq2bam (GPU) → featureCounts (CPU)
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
params.project_name     = "rnaseq_gpu_project"
params.reads            = null
params.reference        = null
params.gtf              = null
params.outdir           = null
params.star_index       = null
params.num_gpus         = 1

params.fastqc_image     = "biocontainers/fastqc:v0.11.9_cv8"
params.fastp_image      = "quay.io/biocontainers/fastp:0.23.4--h5f740d0_0"
params.star_image       = "quay.io/biocontainers/star:2.7.11a--h0033a41_0"
params.parabricks_image = "nvcr.io/nvidia/clara/clara-parabricks:4.7.0-1"
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

// ── Process 3: STAR Indexing (Optional - CPU) ─────────────────────────────────
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

// ── Process 4: rna_fq2bam (GPU) ───────────────────────────────────────────────
process GPU_FQ2BAM_RNA {
    tag "${meta.id}"
    publishDir "${params.outdir}/star_bam", mode: 'copy'
    container params.parabricks_image
    accelerator 1, type: 'nvidia.com/gpu'
    maxForks (params.num_gpus as int)
    errorStrategy 'retry'
    maxRetries 1

    input:
    tuple val(meta), path(r1), path(r2)
    path fasta
    path index

    output:
    tuple val(meta), path("${meta.id}Aligned.sortedByCoord.out.bam"), emit: bam

    script:
    def env_override = "export LD_LIBRARY_PATH=/usr/local/nvidia/lib:/usr/local/nvidia/lib64"
    """
    ${env_override}
    ${getParabricksSpaceFix()}
    echo "INFO: Parabricks rna_fq2bam for ${meta.id}"
    
    pbrun rna_fq2bam \
         --ref ${fasta} \
         --in-fq ${r1} ${r2} \
         --read-files-command zcat \
         --genome-lib-dir ${index} \
         --output-dir . \
         --out-bam ${meta.id}Aligned.sortedByCoord.out.bam \
         --out-prefix ${meta.id} \
         --num-gpus 1
    """
}

// ── Process 5: featureCounts (CPU) ────────────────────────────────────────────
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
    GPU_FQ2BAM_RNA(FASTP.out.trimmed_reads, ch_fasta, ch_star_index)
    FEATURE_COUNTS(GPU_FQ2BAM_RNA.out.bam, ch_gtf)
    
    // Generate Publication Chart
}
