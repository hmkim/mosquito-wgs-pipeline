#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
# run_haplotypecaller_only.sh
# Run only HaplotypeCaller step on existing dedup BAM
# Usage: ./run_haplotypecaller_only.sh <sample_id>
# ─────────────────────────────────────────────────────────

WGS_HOME="${WGS_HOME:-/home/ec2-user/wgs-pipeline}"
REF_DIR="${WGS_HOME}/reference/mosquito/AaegL5"
REF="${REF_DIR}/AaegL5.fasta"
LOG_DIR="${WGS_HOME}/logs"

SAMPLE_ID="${1:?Usage: $0 <sample_id>}"

OUTDIR="${WGS_HOME}/results/gatk/${SAMPLE_ID}"
mkdir -p "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/haplotypecaller_${SAMPLE_ID}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================"
echo " HaplotypeCaller Only: ${SAMPLE_ID}"
echo " Start: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

# Verify inputs
DEDUP_BAM="${OUTDIR}/${SAMPLE_ID}.dedup.bam"
DEDUP_BAI="${OUTDIR}/${SAMPLE_ID}.dedup.bai"
for f in "${REF}" "${REF}.fai" "${REF_DIR}/AaegL5.dict" "${DEDUP_BAM}" "${DEDUP_BAI}"; do
    if [ ! -f "$f" ]; then
        echo "[ERROR] Required file not found: $f"
        exit 1
    fi
done
echo "[OK] All input files verified"
echo "  Dedup BAM: $(du -h ${DEDUP_BAM} | cut -f1)"

# Remove incomplete gVCF from previous run
rm -f "${OUTDIR}/${SAMPLE_ID}.g.vcf.gz" "${OUTDIR}/${SAMPLE_ID}.g.vcf.gz.tbi"

# HaplotypeCaller
echo ""
echo "--- HaplotypeCaller (gVCF mode) ---"
STEP_START=$(date +%s)
gatk HaplotypeCaller \
    -R "${REF}" \
    -I "${DEDUP_BAM}" \
    -O "${OUTDIR}/${SAMPLE_ID}.g.vcf.gz" \
    -ERC GVCF \
    --min-base-quality-score 20

echo "[OK] gVCF generated"
ls -lh "${OUTDIR}/${SAMPLE_ID}.g.vcf.gz"*
HC_TIME=$(( $(date +%s) - STEP_START ))
echo "[TIME] HaplotypeCaller: ${HC_TIME}s ($(( HC_TIME / 3600 ))h $(( (HC_TIME % 3600) / 60 ))m $(( HC_TIME % 60 ))s)"

# gVCF stats
echo ""
echo "gVCF stats:"
bcftools stats "${OUTDIR}/${SAMPLE_ID}.g.vcf.gz" | grep "^SN"

# Upload to S3
if [ -n "${DATA_BUCKET:-}" ]; then
    echo ""
    echo "[INFO] Uploading gVCF to S3..."
    aws s3 cp "${OUTDIR}/${SAMPLE_ID}.g.vcf.gz" \
        "s3://${DATA_BUCKET}/results/gatk/${SAMPLE_ID}/${SAMPLE_ID}.g.vcf.gz"
    aws s3 cp "${OUTDIR}/${SAMPLE_ID}.g.vcf.gz.tbi" \
        "s3://${DATA_BUCKET}/results/gatk/${SAMPLE_ID}/${SAMPLE_ID}.g.vcf.gz.tbi"
    echo "[OK] S3 upload complete"
fi

echo ""
echo "============================================"
echo " Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"
