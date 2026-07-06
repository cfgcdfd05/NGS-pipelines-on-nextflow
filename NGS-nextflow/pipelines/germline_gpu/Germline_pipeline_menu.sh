#!/bin/bash

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$PROJECT_DIR/results"

# ── Path helper: convert Windows path to Linux if needed ──────────────────────
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

# Case-insensitive directory existence check — returns the ACTUAL path on disk
# (handles Windows paths typed with different case than the real Linux path)
resolve_dir_ci() {
    local path="$1"
    if [[ -d "$path" ]]; then
        echo "$path"
        return 0
    fi
    # Try case-insensitive match component by component
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

ask_for_dir() {
    local prompt="$1"
    local check_file="$2"   # optional filename (case-insensitive) that must exist inside the dir

    while true; do
        read -r -p "$prompt" raw >&2
	echo "DEBUG RAW = [$raw]" >&2
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
        resolved=$(resolve_dir_ci "$converted")

        if [[ -z "$resolved" ]]; then
            echo "" >&2
            echo "ERROR: Folder not found: $converted" >&2
            echo "Type '"'"'no'"'"' to exit." >&2
            echo "" >&2
            continue
        fi

        if [[ -n "$check_file" ]]; then
            local found
            found=$(find "$resolved" -maxdepth 1 -iname "$check_file" 2>/dev/null | head -n1)
            if [[ -z "$found" ]]; then
                echo "" >&2
                echo "ERROR: '$check_file' not found in: $resolved" >&2
                echo "Type '"'"'no'"'"' to exit." >&2
                echo "" >&2
                continue
            fi
        fi

        echo "$resolved"
        return 0
    done
}

while true; do
    clear
    echo "============================================"
    echo " GERMLINE VARIANT CALLING PIPELINE"
    echo "============================================"
    echo ""

    # Cohort name
    read -p "Enter cohort name (or 'no' to exit): " COHORT_NAME
    [[ "${COHORT_NAME,,}" == "no" ]] && echo "" && echo "Goodbye!" && sleep 1 && exit 0
    if [[ -z "$COHORT_NAME" ]]; then
        echo "ERROR: Cohort name cannot be empty."
        read -p "Press Enter to try again..."
        continue
    fi

    # Reference folder
    echo ""
    echo "Enter the name of your reference file (e.g., hg38.fasta): "
    read -p "Reference file name: " REF_NAME
    while [[ -z "$REF_NAME" ]]; do
        read -p "Reference file name: " REF_NAME
    done

    echo ""
    echo "Enter the path to your reference genome folder."
    echo "Must contain: $REF_NAME, $REF_NAME.fai, .dict,"
    echo "              $REF_NAME.bwt/.amb/.ann/.pac/.sa"
    echo "Type 'no' to exit."
    echo ""
    REF_DIR=$(ask_for_dir "Reference folder path: " "$REF_NAME")

    # FASTQ folder
    echo ""
    echo "Enter the path to your FASTQ files folder."
    echo "Must contain files named: samplename_R1.fastq.gz / samplename_R2.fastq.gz"
    echo "Type 'no' to exit."
    echo ""

    while true; do
        FASTQ_PATH=$(ask_for_dir "FASTQ folder path: " "")
        R1_COUNT=$(find "$FASTQ_PATH" -maxdepth 1 -iname "*_R1.fastq.gz" 2>/dev/null | wc -l)
        if [[ "$R1_COUNT" -eq 0 ]]; then
            echo ""
            echo "ERROR: No *_R1.fastq.gz files found in: $FASTQ_PATH"
            echo "Type 'no' to exit."
            echo ""
            continue
        fi
        break
    done

    # Results folder — always ./results relative to this script's location
    mkdir -p "$RESULTS_DIR"

    echo ""
    echo "============================================"
    echo " Cohort     : $COHORT_NAME"
    echo " Reference  : $REF_DIR"
    echo " FASTQ      : $FASTQ_PATH"
    echo " Results    : $RESULTS_DIR/$COHORT_NAME"
    echo " Samples    : $R1_COUNT"
    echo "============================================"
    echo " Starting pipeline. Do not close this window."
    echo " This may take several hours."
    echo "============================================"
    echo ""

    REF_DIR="$REF_DIR" REF_NAME="$REF_NAME" RESULTS_DIR="$RESULTS_DIR" \
        bash "$PROJECT_DIR/Germline_pipeline_run.sh" "$COHORT_NAME" "$FASTQ_PATH"
    EXIT_CODE=$?

    echo ""
    if [[ $EXIT_CODE -eq 0 ]]; then
        echo "============================================"
        echo " Pipeline completed successfully!"
        echo " Results: $RESULTS_DIR/$COHORT_NAME/"
        echo "============================================"
    else
        echo "============================================"
        echo " Pipeline failed. Check the output above."
        echo " Fix the issue and run again."
        echo "============================================"
    fi

    echo ""
    read -p "Run another cohort? (yes / no): " AGAIN
    [[ "${AGAIN,,}" != "yes" ]] && echo "" && echo "Goodbye!" && sleep 1 && exit 0

done
