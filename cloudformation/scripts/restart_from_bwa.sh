#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
# restart_from_bwa.sh
# Restart pipeline from BWA-mem2 step (skips FastQC/FastP)
# Usage: ./restart_from_bwa.sh <sample_id> [threads]
# Assumes trimmed FASTQs already exist in results dir
# ─────────────────────────────────────────────────────────

WGS_HOME="${WGS_HOME:-/home/ec2-user/wgs-pipeline}"
REF_DIR="${WGS_HOME}/reference/mosquito/AaegL5"
REF="${REF_DIR}/AaegL5.fasta"
LOG_DIR="${WGS_HOME}/logs"

SAMPLE_ID="${1:?Usage: $0 <sample_id> [threads]}"
THREADS="${2:-16}"

OUTDIR="${WGS_HOME}/results/gatk/${SAMPLE_ID}"
mkdir -p "${OUTDIR}" "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/restart_bwa_${SAMPLE_ID}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================"
echo " Restart from BWA-mem2: ${SAMPLE_ID}"
echo " Threads: ${THREADS}"
echo " Start: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

# Verify trimmed FASTQs exist
TRIM_R1="${OUTDIR}/${SAMPLE_ID}_trimmed_R1.fastq.gz"
TRIM_R2="${OUTDIR}/${SAMPLE_ID}_trimmed_R2.fastq.gz"
for f in "${REF}" "${REF}.fai" "${REF_DIR}/AaegL5.dict" "${REF}.bwt.2bit.64" "${TRIM_R1}" "${TRIM_R2}"; do
    if [ ! -f "$f" ]; then
        echo "[ERROR] Required file not found: $f"
        exit 1
    fi
done
echo "[OK] All input files verified"
echo "  Trimmed R1: $(du -h ${TRIM_R1} | cut -f1)"
echo "  Trimmed R2: $(du -h ${TRIM_R2} | cut -f1)"

# Remove incomplete BAM from previous run
rm -f "${OUTDIR}/${SAMPLE_ID}.aligned.bam"

# ─── Step 3: BWA-mem2 Alignment ───
echo ""
echo "--- Step 3/6: BWA-mem2 Alignment ---"
STEP_START=$(date +%s)
bwa-mem2 mem \
    -t ${THREADS} \
    -R "@RG\tID:${SAMPLE_ID}\tSM:${SAMPLE_ID}\tPL:ILLUMINA\tLB:lib1" \
    "${REF}" \
    "${TRIM_R1}" \
    "${TRIM_R2}" \
| samtools view -bS -@ 2 - > "${OUTDIR}/${SAMPLE_ID}.aligned.bam"

echo "[OK] Alignment complete"
samtools flagstat "${OUTDIR}/${SAMPLE_ID}.aligned.bam" | head -3
STEP3_TIME=$(( $(date +%s) - STEP_START ))
echo "[TIME] BWA-mem2: ${STEP3_TIME}s"

# ─── Step 4: Sort & Index ───
echo ""
echo "--- Step 4/6: Sort & Index ---"
STEP_START=$(date +%s)
samtools sort -@ 4 -o "${OUTDIR}/${SAMPLE_ID}.sorted.bam" "${OUTDIR}/${SAMPLE_ID}.aligned.bam"
samtools index "${OUTDIR}/${SAMPLE_ID}.sorted.bam"
echo "[OK] BAM sorted and indexed"
rm -f "${OUTDIR}/${SAMPLE_ID}.aligned.bam"
STEP4_TIME=$(( $(date +%s) - STEP_START ))
echo "[TIME] Sort & Index: ${STEP4_TIME}s"

# ─── Step 5: MarkDuplicates ───
echo ""
echo "--- Step 5/6: MarkDuplicates ---"
STEP_START=$(date +%s)
gatk MarkDuplicates \
    -I "${OUTDIR}/${SAMPLE_ID}.sorted.bam" \
    -O "${OUTDIR}/${SAMPLE_ID}.dedup.bam" \
    -M "${OUTDIR}/${SAMPLE_ID}.dedup_metrics.txt" \
    --REMOVE_DUPLICATES false \
    --CREATE_INDEX true

echo "[OK] Duplicates marked"
grep -A 2 "LIBRARY" "${OUTDIR}/${SAMPLE_ID}.dedup_metrics.txt" || true
rm -f "${OUTDIR}/${SAMPLE_ID}.sorted.bam" "${OUTDIR}/${SAMPLE_ID}.sorted.bam.bai"
STEP5_TIME=$(( $(date +%s) - STEP_START ))
echo "[TIME] MarkDuplicates: ${STEP5_TIME}s"

# ─── Step 6: HaplotypeCaller (gVCF) ───
echo ""
echo "--- Step 6/6: HaplotypeCaller ---"
STEP_START=$(date +%s)
gatk HaplotypeCaller \
    -R "${REF}" \
    -I "${OUTDIR}/${SAMPLE_ID}.dedup.bam" \
    -O "${OUTDIR}/${SAMPLE_ID}.g.vcf.gz" \
    -ERC GVCF \
    --min-base-quality-score 20

echo "[OK] gVCF generated"
ls -lh "${OUTDIR}/${SAMPLE_ID}.g.vcf.gz"*
STEP6_TIME=$(( $(date +%s) - STEP_START ))
echo "[TIME] HaplotypeCaller: ${STEP6_TIME}s"

# ─── Summary ───
echo ""
echo "============================================"
echo " Restart Pipeline Summary: ${SAMPLE_ID}"
echo "============================================"
echo " BWA-mem2:       ${STEP3_TIME}s"
echo " Sort & Index:   ${STEP4_TIME}s"
echo " MarkDuplicates: ${STEP5_TIME}s"
echo " HaplotypeCaller:${STEP6_TIME}s"
TOTAL_TIME=$(( STEP3_TIME + STEP4_TIME + STEP5_TIME + STEP6_TIME ))
echo " ────────────────────────"
echo " Total:          ${TOTAL_TIME}s ($(( TOTAL_TIME / 60 ))m $(( TOTAL_TIME % 60 ))s)"
echo ""

echo "Output files:"
ls -lh "${OUTDIR}/"
echo ""

echo "gVCF stats:"
bcftools stats "${OUTDIR}/${SAMPLE_ID}.g.vcf.gz" | head -30

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
