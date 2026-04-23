#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
# 04_joint_genotyping.sh
# Joint genotyping: GenomicsDBImport → GenotypeGVCFs → Filter
# Usage: ./04_joint_genotyping.sh <cohort_name> <sample1_id> [sample2_id ...]
# ─────────────────────────────────────────────────────────

WGS_HOME="${WGS_HOME:-/home/ec2-user/wgs-pipeline}"
REF_DIR="${WGS_HOME}/reference/mosquito/AaegL5"
REF="${REF_DIR}/AaegL5.fasta"
RESULTS_DIR="${WGS_HOME}/results/gatk"
LOG_DIR="${WGS_HOME}/logs"

COHORT="${1:?Usage: $0 <cohort_name> <sample1_id> [sample2_id ...]}"
shift
SAMPLES=("$@")

if [ ${#SAMPLES[@]} -lt 1 ]; then
    echo "[ERROR] At least 1 sample ID required."
    echo "Usage: $0 <cohort_name> <sample1_id> [sample2_id ...]"
    exit 1
fi

mkdir -p "${RESULTS_DIR}" "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/04_joint_genotyping_${COHORT}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================"
echo " Joint Genotyping: ${COHORT}"
echo " Samples: ${SAMPLES[*]}"
echo " Start: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

# ─── Pre-flight: verify all gVCFs exist ───
echo "[INFO] Verifying sample gVCFs..."
SAMPLE_MAP="${RESULTS_DIR}/sample_map_${COHORT}.txt"
> "${SAMPLE_MAP}"

for SID in "${SAMPLES[@]}"; do
    GVCF="${RESULTS_DIR}/${SID}/${SID}.g.vcf.gz"
    GVCF_IDX="${GVCF}.tbi"
    if [ ! -f "${GVCF}" ] || [ ! -f "${GVCF_IDX}" ]; then
        echo "[ERROR] gVCF or index not found for sample: ${SID}"
        echo "  Expected: ${GVCF}"
        echo "  Expected: ${GVCF_IDX}"
        exit 1
    fi
    echo -e "${SID}\t${GVCF}" >> "${SAMPLE_MAP}"
    echo "[OK] ${SID}: $(du -h ${GVCF} | cut -f1)"
done

echo "[OK] Sample map created: ${SAMPLE_MAP}"
cat "${SAMPLE_MAP}"

# ─── Create intervals list (3 chromosomes) ───
INTERVALS="${RESULTS_DIR}/intervals_${COHORT}.list"
echo -e "NC_035107.1\nNC_035108.1\nNC_035109.1" > "${INTERVALS}"
echo ""

# ─── Step 1: GenomicsDBImport ───
echo "--- Step 1/3: GenomicsDBImport ---"
STEP_START=$(date +%s)
GENOMICSDB="${RESULTS_DIR}/genomicsdb_${COHORT}"

# Remove existing workspace if present (GenomicsDBImport cannot overwrite)
if [ -d "${GENOMICSDB}" ]; then
    echo "[WARN] Removing existing workspace: ${GENOMICSDB}"
    rm -rf "${GENOMICSDB}"
fi

gatk GenomicsDBImport \
    --sample-name-map "${SAMPLE_MAP}" \
    --genomicsdb-workspace-path "${GENOMICSDB}" \
    --reader-threads 4 \
    --batch-size 50 \
    -R "${REF}" \
    -L "${INTERVALS}"

echo "[OK] GenomicsDB workspace created"
STEP1_TIME=$(( $(date +%s) - STEP_START ))
echo "[TIME] GenomicsDBImport: ${STEP1_TIME}s"

# ─── Step 2: GenotypeGVCFs ───
echo ""
echo "--- Step 2/3: GenotypeGVCFs ---"
STEP_START=$(date +%s)

gatk GenotypeGVCFs \
    -R "${REF}" \
    -V "gendb://${GENOMICSDB}" \
    -O "${RESULTS_DIR}/${COHORT}.raw.vcf.gz"

echo "[OK] Raw VCF generated"
ls -lh "${RESULTS_DIR}/${COHORT}.raw.vcf.gz"
STEP2_TIME=$(( $(date +%s) - STEP_START ))
echo "[TIME] GenotypeGVCFs: ${STEP2_TIME}s"

# ─── Step 3: Variant Filtering ───
echo ""
echo "--- Step 3/3: Variant Filtering ---"
echo "  Filters (Nature Comms 2025):"
echo "    Site: QD<5, FS>60, ReadPosRankSum<-8"
echo "    Genotype: GQ>20, DP>=10"
STEP_START=$(date +%s)

bcftools filter \
    -e 'INFO/QD < 5 || INFO/FS > 60 || INFO/ReadPosRankSum < -8' \
    "${RESULTS_DIR}/${COHORT}.raw.vcf.gz" | \
bcftools view \
    -i 'FORMAT/GQ > 20 && FORMAT/DP >= 10' \
    -Oz -o "${RESULTS_DIR}/${COHORT}.filtered.vcf.gz"

tabix -p vcf "${RESULTS_DIR}/${COHORT}.filtered.vcf.gz"

echo "[OK] Filtered VCF generated"
STEP3_TIME=$(( $(date +%s) - STEP_START ))
echo "[TIME] Filtering: ${STEP3_TIME}s"

# ─── Summary ───
echo ""
echo "============================================"
echo " Joint Genotyping Summary: ${COHORT}"
echo "============================================"
echo " GenomicsDBImport: ${STEP1_TIME}s"
echo " GenotypeGVCFs:    ${STEP2_TIME}s"
echo " Filtering:        ${STEP3_TIME}s"
TOTAL_TIME=$(( STEP1_TIME + STEP2_TIME + STEP3_TIME ))
echo " ────────────────────────"
echo " Total:            ${TOTAL_TIME}s ($(( TOTAL_TIME / 60 ))m $(( TOTAL_TIME % 60 ))s)"
echo ""

echo "--- Raw VCF stats ---"
bcftools stats "${RESULTS_DIR}/${COHORT}.raw.vcf.gz" | grep "^SN"
echo ""

echo "--- Filtered VCF stats ---"
bcftools stats "${RESULTS_DIR}/${COHORT}.filtered.vcf.gz" | grep "^SN"
echo ""

echo "Output files:"
ls -lh "${RESULTS_DIR}/${COHORT}"*.vcf.gz* 2>/dev/null || true
ls -lh "${RESULTS_DIR}/genomicsdb_${COHORT}/" 2>/dev/null | head -5 || true

# ─── Upload to S3 ───
if [ -n "${DATA_BUCKET:-}" ]; then
    echo ""
    echo "[INFO] Uploading results to S3..."
    aws s3 cp "${RESULTS_DIR}/${COHORT}.filtered.vcf.gz" \
        "s3://${DATA_BUCKET}/results/gatk/${COHORT}.filtered.vcf.gz"
    aws s3 cp "${RESULTS_DIR}/${COHORT}.filtered.vcf.gz.tbi" \
        "s3://${DATA_BUCKET}/results/gatk/${COHORT}.filtered.vcf.gz.tbi"
    aws s3 cp "${RESULTS_DIR}/${COHORT}.raw.vcf.gz" \
        "s3://${DATA_BUCKET}/results/gatk/${COHORT}.raw.vcf.gz"
    echo "[OK] S3 upload complete"
fi

echo ""
echo "============================================"
echo " Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"
