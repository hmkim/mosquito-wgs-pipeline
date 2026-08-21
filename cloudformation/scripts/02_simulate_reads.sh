#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
# 02_simulate_reads.sh
# Generate simulated paired-end reads for pipeline testing
# Usage: ./02_simulate_reads.sh [small|medium]
# ─────────────────────────────────────────────────────────

WGS_HOME="${WGS_HOME:-/home/ec2-user/wgs-pipeline}"
REF_DIR="${WGS_HOME}/reference/mosquito/AaegL5"
TEST_DIR="${WGS_HOME}/test_data"
LOG_DIR="${WGS_HOME}/logs"
mkdir -p "${TEST_DIR}" "${LOG_DIR}"

MODE="${1:-small}"

LOG_FILE="${LOG_DIR}/02_simulate_reads_${MODE}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================"
echo " Step 2: Simulate Reads (mode=${MODE})"
echo " Start: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

# Check reference exists
if [ ! -f "${REF_DIR}/AaegL5.fasta" ]; then
    echo "[ERROR] Reference genome not found. Run 01_prepare_reference.sh first."
    exit 1
fi

if [ "${MODE}" == "small" ]; then
    # ─── Small test: chr1 first 1 Mb, 50K read pairs ───
    echo "[INFO] Extracting chr1 (NC_035107.1) first 1 Mb region..."
    samtools faidx "${REF_DIR}/AaegL5.fasta" NC_035107.1:1-1000000 \
        > "${TEST_DIR}/chr1_1mb.fasta"

    echo "[INFO] Generating 50K paired-end reads (150bp, insert=300bp)..."
    wgsim -N 50000 -1 150 -2 150 \
        -r 0.001 -R 0.1 -d 300 -S 42 \
        "${TEST_DIR}/chr1_1mb.fasta" \
        "${TEST_DIR}/test_R1.fastq" \
        "${TEST_DIR}/test_R2.fastq"

    echo "[INFO] Compressing FASTQ files..."
    gzip -f "${TEST_DIR}/test_R1.fastq"
    gzip -f "${TEST_DIR}/test_R2.fastq"

    echo "[OK] Small test data generated:"
    ls -lh "${TEST_DIR}"/test_R*.fastq.gz

elif [ "${MODE}" == "medium" ]; then
    # ─── Medium test: full chr1, ~10x coverage ───
    # chr1 = 310 Mb → 10x = ~10.3M read pairs (150bp PE)
    echo "[INFO] Generating 10.3M paired-end reads (full chr1, ~10x)..."
    echo "[INFO] This will take ~15-30 minutes..."

    wgsim -N 10300000 -1 150 -2 150 \
        -r 0.001 -R 0.1 -d 300 -S 42 \
        "${REF_DIR}/AaegL5.fasta" \
        "${TEST_DIR}/full_test_R1.fastq" \
        "${TEST_DIR}/full_test_R2.fastq"

    echo "[INFO] Compressing FASTQ files..."
    pigz -p 4 -f "${TEST_DIR}/full_test_R1.fastq" 2>/dev/null || gzip -f "${TEST_DIR}/full_test_R1.fastq"
    pigz -p 4 -f "${TEST_DIR}/full_test_R2.fastq" 2>/dev/null || gzip -f "${TEST_DIR}/full_test_R2.fastq"

    echo "[OK] Medium test data generated:"
    ls -lh "${TEST_DIR}"/full_test_R*.fastq.gz

else
    echo "[ERROR] Unknown mode: ${MODE}. Use 'small' or 'medium'."
    exit 1
fi

# ─── Verification ───
echo ""
echo "============================================"
echo " Verification"
echo "============================================"

for FQ in "${TEST_DIR}"/*.fastq.gz; do
    [ -f "$FQ" ] || continue
    READ_COUNT=$(zcat "$FQ" | head -400 | awk 'NR%4==1' | wc -l)
    SIZE=$(du -h "$FQ" | cut -f1)
    echo "[OK] $(basename $FQ)  size=${SIZE}  first_reads=${READ_COUNT}"
done

echo ""
echo "============================================"
echo " Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"
