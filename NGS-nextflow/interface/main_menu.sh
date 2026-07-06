#!/bin/bash

# Navigate to script directory
INTERFACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(dirname "$INTERFACE_DIR")"
RESULTS_DIR="$APP_ROOT/results"

# ── Path helpers ──────────────────────────────────────────────────────────────
to_linux_path() {
    local path="$1"
    if [[ "$path" =~ ^[A-Za-z]:[\\/] ]]; then
        local drive="${path:0:1}"
        local rest="${path:2}"
        rest="${rest//\\//}"
        echo "/mnt/${drive,,}${rest}"
    else
        echo "$path"
    fi
}

resolve_dir_ci() {
    local path="$1"
    if [[ -d "$path" ]]; then
        echo "$path"
        return 0
    fi
    local current="/"
    local IFS='/'
    read -ra parts <<< "$path"
    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue
        local match
        match=$(find "$current" -maxdepth 1 -iname "$part" 2>/dev/null | head -n1)
        if [[ -n "$match" ]]; then
            current="$match"
        else
            return 1
        fi
    done
    echo "$current"
    return 0
}

ask_for_path() {
    local prompt="$1"
    local require_dir="$2"
    local check_file="$3"

    while true; do
        read -r -p "$prompt" raw >&2
        if [[ "${raw,,}" == "no" || "${raw,,}" == "exit" ]]; then
            echo "" >&2
            echo "Goodbye!" >&2
            sleep 1
            exit 0
        fi
        if [[ -z "$raw" ]]; then
            echo "ERROR: Path cannot be empty." >&2
            continue
        fi

        local converted resolved
        converted=$(to_linux_path "$raw")
        
        if [[ "$require_dir" == "1" ]]; then
            resolved=$(resolve_dir_ci "$converted")
            if [[ -z "$resolved" ]]; then
                echo "" >&2
                echo "ERROR: Folder not found: $converted" >&2
                continue
            fi
            if [[ -n "$check_file" ]]; then
                local found
                found=$(find "$resolved" -maxdepth 1 -iname "$check_file" 2>/dev/null | head -n1)
                if [[ -z "$found" ]]; then
                    echo "" >&2
                    echo "ERROR: '$check_file' not found in: $resolved" >&2
                    continue
                fi
            fi
            echo "$resolved"
            return 0
        else
            # For files, just check if it exists or use basic converted path
            if [[ -f "$converted" ]]; then
                echo "$converted"
                return 0
            else
                echo "" >&2
                echo "ERROR: File not found: $converted" >&2
                continue
            fi
        fi
    done
}

while true; do
    clear
    echo "=========================================================="
    echo " NEXTFLOW GERMLINE VARIANT CALLING - MAIN INTERFACE"
    echo "=========================================================="
    echo ""

    # Check Docker GPU visibility once on load
    if [[ -z "$GPU_CHECKED" ]]; then
        export GPU_CHECKED=1
        if command -v docker &> /dev/null; then
            echo -n "Checking GPU visibility for Docker containers... "
            if docker run --rm --runtime=nvidia nvcr.io/nvidia/clara/clara-parabricks:4.7.0-1 nvidia-smi &> /dev/null; then
                echo -e "\033[32mOK\033[0m"
            else
                echo -e "\033[31mFAILED\033[0m"
                echo "WARNING: Docker cannot access the GPU using the NVIDIA runtime."
                echo "Please check your NVIDIA Container Toolkit installation."
                echo ""
                sleep 2
            fi
        fi
    fi
    echo "=========================================================="
    echo "Please choose the pipeline you wish to run:"
    echo "  1) Germline CPU Pipeline (BWA, GATK 4)"
    echo "  2) Germline GPU Pipeline (NVIDIA Parabricks)"
    echo "  3) ChIP-seq GPU Pipeline (NVIDIA Parabricks, MACS2)"
    echo "  4) ChIP-seq CPU Pipeline (BWA, MACS2)"
    echo "  5) Exit"
    echo "=========================================================="
    read -p "Selection (1/2/3/4/5): " PIPELINE_CHOICE

    if [[ "$PIPELINE_CHOICE" == "5" ]]; then
        echo "Goodbye!"
        exit 0
    elif [[ ! "$PIPELINE_CHOICE" =~ ^[1-4]$ ]]; then
        echo "Invalid selection."
        sleep 1
        continue
    fi

    echo ""
    echo "----------------------------------------------------------"
    echo " REFERENCE INDEXING"
    echo "----------------------------------------------------------"
    echo "Pre-built BWA files and sequence dictionaries (.bwt, .fai, .dict, etc.)"
    echo "are REQUIRED for BOTH pipelines to function properly."
    echo ""
    read -p "Do you need to build the reference index now? (y/n): " BUILD_REF

    if [[ "${BUILD_REF,,}" == "y" || "${BUILD_REF,,}" == "yes" ]]; then
        echo ""
        echo "Please provide the absolute path to the reference fasta file."
        echo "Example: D:\Data\Ref\reference.fasta"
        REF_FILE_PATH=$(ask_for_path "Reference Fasta File path: " "0" "")
        
        echo "Building reference indexes..."
        bash "$APP_ROOT/pipelines/germline_cpu/Germline_CPU_reference_builder.sh" "$REF_FILE_PATH"
        echo "Indexing process finished."
        read -p "Press Enter to continue to the pipeline setup..." 
    fi

    echo ""
    echo "----------------------------------------------------------"
    echo " PIPELINE CONFIGURATION"
    echo "----------------------------------------------------------"
    
    # Cohort name
    read -p "Enter cohort name (e.g., cohort_01) or 'no' to exit: " COHORT_NAME
    [[ "${COHORT_NAME,,}" == "no" ]] && exit 0
    while [[ -z "$COHORT_NAME" ]]; do
        echo "ERROR: Cohort name cannot be empty."
        read -p "Enter cohort name: " COHORT_NAME
    done

    # Reference name
    echo ""
    read -p "Enter the name of your reference file (e.g., hg38.fasta): " REF_NAME
    while [[ -z "$REF_NAME" ]]; do
        read -p "Enter the name of your reference file (e.g., hg38.fasta): " REF_NAME
    done

    # Reference folder
    echo ""
    echo "Enter the path to your reference genome FOLDER."
    echo "Must contain: $REF_NAME and all indexed files (.bwt, .fai, .dict, etc.)"
    REF_DIR=$(ask_for_path "Reference folder path: " "1" "$REF_NAME")

    # FASTQ folder
    echo ""
    echo "Enter the path to your FASTQ files folder."
    echo "Files MUST be named in the format: {samplename}_R1.fastq.gz and {samplename}_R2.fastq.gz"
    
    while true; do
        FASTQ_PATH=$(ask_for_path "FASTQ folder path: " "1" "")
        R1_COUNT=$(find "$FASTQ_PATH" -maxdepth 1 -iname "*_R1.fastq.gz" 2>/dev/null | wc -l)
        if [[ "$R1_COUNT" -eq 0 ]]; then
            echo ""
            echo "ERROR: No *_R1.fastq.gz files found in: $FASTQ_PATH"
            continue
        fi
        break
    done

    # Run Pipeline
    mkdir -p "$RESULTS_DIR"

    echo ""
    echo "=========================================================="
    echo " RUN SUMMARY"
    echo "=========================================================="
    if [[ "$PIPELINE_CHOICE" == "1" ]]; then
        echo " Pipeline   : Germline CPU"
    elif [[ "$PIPELINE_CHOICE" == "2" ]]; then
        echo " Pipeline   : Germline GPU (Parabricks)"
    elif [[ "$PIPELINE_CHOICE" == "3" ]]; then
        echo " Pipeline   : ChIP-seq GPU (Parabricks)"
    elif [[ "$PIPELINE_CHOICE" == "4" ]]; then
        echo " Pipeline   : ChIP-seq CPU"
    fi
    echo " Cohort     : $COHORT_NAME"
    echo " Reference  : $REF_DIR"
    echo " FASTQ      : $FASTQ_PATH"
    echo " Results    : $RESULTS_DIR/$COHORT_NAME"
    echo " Samples    : $R1_COUNT"
    echo "=========================================================="
    echo " Starting pipeline. Do not close this window."
    echo "=========================================================="
    echo ""

    if [[ "$PIPELINE_CHOICE" == "1" ]]; then
        REF_DIR="$REF_DIR" REF_NAME="$REF_NAME" RESULTS_DIR="$RESULTS_DIR" \
        bash "$APP_ROOT/pipelines/germline_cpu/Germline_CPU_run.sh" "$COHORT_NAME" "$FASTQ_PATH"
    elif [[ "$PIPELINE_CHOICE" == "2" ]]; then
        REF_DIR="$REF_DIR" REF_NAME="$REF_NAME" RESULTS_DIR="$RESULTS_DIR" \
        bash "$APP_ROOT/pipelines/germline_gpu/Germline_pipeline_run.sh" "$COHORT_NAME" "$FASTQ_PATH"
    elif [[ "$PIPELINE_CHOICE" == "3" ]]; then
        REF_DIR="$REF_DIR" REF_NAME="$REF_NAME" RESULTS_DIR="$RESULTS_DIR" \
        bash "$APP_ROOT/pipelines/chipseq/CHIPseq_GPU_run.sh" "$COHORT_NAME" "$FASTQ_PATH"
    elif [[ "$PIPELINE_CHOICE" == "4" ]]; then
        REF_DIR="$REF_DIR" REF_NAME="$REF_NAME" RESULTS_DIR="$RESULTS_DIR" \
        bash "$APP_ROOT/pipelines/chipseq_cpu/CHIPseq_CPU_run.sh" "$COHORT_NAME" "$FASTQ_PATH"
    fi
    
    EXIT_CODE=$?

    echo ""
    if [[ $EXIT_CODE -eq 0 ]]; then
        echo "=========================================================="
        echo " Pipeline completed successfully!"
        echo " Results: $RESULTS_DIR/$COHORT_NAME/"
        echo "=========================================================="
    else
        echo "=========================================================="
        echo " Pipeline failed. Please check the logs above."
        echo "=========================================================="
    fi

    echo ""
    read -p "Run another cohort? (y/n): " AGAIN
    [[ "${AGAIN,,}" != "y" && "${AGAIN,,}" != "yes" ]] && echo "Goodbye!" && exit 0
done
