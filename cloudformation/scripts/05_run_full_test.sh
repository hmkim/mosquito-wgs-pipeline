#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
# 05_run_full_test.sh
# End-to-end pipeline test: runs all steps sequentially
# Creates 2 simulated samples and performs joint genotyping
# ─────────────────────────────────────────────────────────

WGS_HOME="${WGS_HOME:-/home/ec2-user/wgs-pipeline}"
SCRIPTS_DIR="${WGS_HOME}/scripts"
LOG_DIR="${WGS_HOME}/logs"
mkdir -p "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/05_full_test_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================"
echo " Full Pipeline E2E Test"
echo " Start: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

PIPELINE_START=$(date +%s)

# ─── Step 1: Prepare Reference ───
echo ""
echo ">>> Running 01_prepare_reference.sh"
bash "${SCRIPTS_DIR}/01_prepare_reference.sh"

# ─── Step 2: Generate test data (small) ───
echo ""
echo ">>> Running 02_simulate_reads.sh (small)"
bash "${SCRIPTS_DIR}/02_simulate_reads.sh" small

# ─── Step 3: Run per-sample pipeline — Sample 1 ───
echo ""
echo ">>> Running 03_run_per_sample.sh for test_sample_001"
bash "${SCRIPTS_DIR}/03_run_per_sample.sh" \
    test_sample_001 \
    "${WGS_HOME}/test_data/test_R1.fastq.gz" \
    "${WGS_HOME}/test_data/test_R2.fastq.gz"

# ─── Step 3b: Generate second sample with different seed ───
echo ""
echo ">>> Generating second test sample..."
TEST_DIR="${WGS_HOME}/test_data"
wgsim -N 50000 -1 150 -2 150 \
    -r 0.002 -R 0.1 -d 300 -S 99 \
    "${TEST_DIR}/chr1_1mb.fasta" \
    "${TEST_DIR}/test2_R1.fastq" \
    "${TEST_DIR}/test2_R2.fastq"
gzip -f "${TEST_DIR}/test2_R1.fastq"
gzip -f "${TEST_DIR}/test2_R2.fastq"

echo ">>> Running 03_run_per_sample.sh for test_sample_002"
bash "${SCRIPTS_DIR}/03_run_per_sample.sh" \
    test_sample_002 \
    "${TEST_DIR}/test2_R1.fastq.gz" \
    "${TEST_DIR}/test2_R2.fastq.gz"

# ─── Step 4: Joint Genotyping ───
echo ""
echo ">>> Running 04_joint_genotyping.sh"
bash "${SCRIPTS_DIR}/04_joint_genotyping.sh" \
    test_cohort \
    test_sample_001 \
    test_sample_002

# ─── Final Verification ───
PIPELINE_END=$(date +%s)
TOTAL_TIME=$(( PIPELINE_END - PIPELINE_START ))

echo ""
echo "============================================"
echo " E2E Test Verification Checklist"
echo "============================================"

PASS=0
FAIL=0

check_file() {
    local label="$1"
    local path="$2"
    if [ -f "$path" ] && [ -s "$path" ]; then
        echo "[PASS] ${label}: $(du -h $path | cut -f1)"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] ${label}: $path"
        FAIL=$((FAIL + 1))
    fi
}

check_dir() {
    local label="$1"
    local path="$2"
    if [ -d "$path" ]; then
        echo "[PASS] ${label}: exists"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] ${label}: $path"
        FAIL=$((FAIL + 1))
    fi
}

REF_DIR="${WGS_HOME}/reference/mosquito/AaegL5"
RESULTS="${WGS_HOME}/results/gatk"

echo ""
echo "--- Reference ---"
check_file "AaegL5.fasta"        "${REF_DIR}/AaegL5.fasta"
check_file "AaegL5.fasta.fai"    "${REF_DIR}/AaegL5.fasta.fai"
check_file "AaegL5.dict"         "${REF_DIR}/AaegL5.dict"
check_file "BWA index (bwt)"     "${REF_DIR}/AaegL5.fasta.bwt.2bit.64"

echo ""
echo "--- Sample 1 ---"
check_file "FastQC HTML"         "$(ls ${RESULTS}/test_sample_001/*fastqc.html 2>/dev/null | head -1)"
check_file "FastP HTML"          "${RESULTS}/test_sample_001/test_sample_001_fastp.html"
check_file "Dedup BAM"           "${RESULTS}/test_sample_001/test_sample_001.dedup.bam"
check_file "Dedup metrics"       "${RESULTS}/test_sample_001/test_sample_001.dedup_metrics.txt"
check_file "gVCF"                "${RESULTS}/test_sample_001/test_sample_001.g.vcf.gz"
check_file "gVCF index"          "${RESULTS}/test_sample_001/test_sample_001.g.vcf.gz.tbi"

echo ""
echo "--- Sample 2 ---"
check_file "gVCF"                "${RESULTS}/test_sample_002/test_sample_002.g.vcf.gz"
check_file "gVCF index"          "${RESULTS}/test_sample_002/test_sample_002.g.vcf.gz.tbi"

echo ""
echo "--- Joint Genotyping ---"
check_dir  "GenomicsDB"          "${RESULTS}/genomicsdb_test_cohort"
check_file "Raw VCF"             "${RESULTS}/test_cohort.raw.vcf.gz"
check_file "Filtered VCF"        "${RESULTS}/test_cohort.filtered.vcf.gz"
check_file "Filtered VCF index"  "${RESULTS}/test_cohort.filtered.vcf.gz.tbi"

echo ""
echo "============================================"
echo " Results: ${PASS} passed, ${FAIL} failed"
echo " Total time: ${TOTAL_TIME}s ($(( TOTAL_TIME / 60 ))m $(( TOTAL_TIME % 60 ))s)"
echo " Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

if [ ${FAIL} -gt 0 ]; then
    echo "[WARNING] Some checks failed. Review logs in ${LOG_DIR}/"
    exit 1
fi

echo "[SUCCESS] Full pipeline test passed!"
