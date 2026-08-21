#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
# 03_run_per_sample.sh
# Per-sample WGS pipeline: FastQC → FastP → BWA-mem2 → Sort → MarkDup → HaplotypeCaller
# Usage: ./03_run_per_sample.sh <sample_id> <fastq_r1> <fastq_r2>
# ─────────────────────────────────────────────────────────

WGS_HOME="${WGS_HOME:-/home/ec2-user/wgs-pipeline}"
REF_DIR="${WGS_HOME}/reference/mosquito/AaegL5"
REF="${REF_DIR}/AaegL5.fasta"
LOG_DIR="${WGS_HOME}/logs"

SAMPLE_ID="${1:?Usage: $0 <sample_id> <fastq_r1> <fastq_r2>}"
FASTQ_R1="${2:?Provide R1 FASTQ path}"
FASTQ_R2="${3:?Provide R2 FASTQ path}"
THREADS="${4:-8}"

OUTDIR="${WGS_HOME}/results/gatk/${SAMPLE_ID}"
mkdir -p "${OUTDIR}" "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/03_per_sample_${SAMPLE_ID}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================"
echo " Per-Sample Pipeline: ${SAMPLE_ID}"
echo " R1: ${FASTQ_R1}"
echo " R2: ${FASTQ_R2}"
echo " Threads: ${THREADS}"
echo " Start: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

# ─── Pre-flight checks ───
for f in "${REF}" "${REF}.fai" "${REF_DIR}/AaegL5.dict" "${REF}.bwt.2bit.64" "${FASTQ_R1}" "${FASTQ_R2}"; do
    if [ ! -f "$f" ]; then
        echo "[ERROR] Required file not found: $f"
        exit 1
    fi
done
echo "[OK] All input files verified"

STEP_START=$(date +%s)

# ─── Step 1: FastQC ───
echo ""
echo "--- Step 1/6: FastQC ---"
fastqc "${FASTQ_R1}" "${FASTQ_R2}" -o "${OUTDIR}" --threads 2
echo "[OK] FastQC reports generated"
ls "${OUTDIR}"/*fastqc.html 2>/dev/null || echo "[WARN] No FastQC HTML found"
STEP1_TIME=$(( $(date +%s) - STEP_START ))
echo "[TIME] FastQC: ${STEP1_TIME}s"

# ─── Step 2: FastP (Trimming) ───
echo ""
echo "--- Step 2/6: FastP ---"
STEP_START=$(date +%s)
fastp \
    --in1 "${FASTQ_R1}" \
    --in2 "${FASTQ_R2}" \
    --out1 "${OUTDIR}/${SAMPLE_ID}_trimmed_R1.fastq.gz" \
    --out2 "${OUTDIR}/${SAMPLE_ID}_trimmed_R2.fastq.gz" \
    --html "${OUTDIR}/${SAMPLE_ID}_fastp.html" \
    --json "${OUTDIR}/${SAMPLE_ID}_fastp.json" \
    --thread 4 \
    --qualified_quality_phred 20 \
    --length_required 50

# Verify trimmed files
for f in "${OUTDIR}/${SAMPLE_ID}_trimmed_R1.fastq.gz" "${OUTDIR}/${SAMPLE_ID}_trimmed_R2.fastq.gz"; do
    if [ ! -s "$f" ]; then
        echo "[ERROR] Trimmed file is empty: $f"
        exit 1
    fi
done
echo "[OK] Trimmed reads created"
STEP2_TIME=$(( $(date +%s) - STEP_START ))
echo "[TIME] FastP: ${STEP2_TIME}s"

# ─── Step 3: BWA-mem2 Alignment ───
echo ""
echo "--- Step 3/6: BWA-mem2 Alignment ---"
STEP_START=$(date +%s)
bwa-mem2 mem \
    -t ${THREADS} \
    -R "@RG\tID:${SAMPLE_ID}\tSM:${SAMPLE_ID}\tPL:ILLUMINA\tLB:lib1" \
    "${REF}" \
    "${OUTDIR}/${SAMPLE_ID}_trimmed_R1.fastq.gz" \
    "${OUTDIR}/${SAMPLE_ID}_trimmed_R2.fastq.gz" \
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

# Remove unsorted BAM to save space
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

# Remove sorted BAM to save space
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
echo " Pipeline Summary: ${SAMPLE_ID}"
echo "============================================"
echo " FastQC:         ${STEP1_TIME}s"
echo " FastP:          ${STEP2_TIME}s"
echo " BWA-mem2:       ${STEP3_TIME}s"
echo " Sort & Index:   ${STEP4_TIME}s"
echo " MarkDuplicates: ${STEP5_TIME}s"
echo " HaplotypeCaller:${STEP6_TIME}s"
TOTAL_TIME=$(( STEP1_TIME + STEP2_TIME + STEP3_TIME + STEP4_TIME + STEP5_TIME + STEP6_TIME ))
echo " ────────────────────────"
echo " Total:          ${TOTAL_TIME}s ($(( TOTAL_TIME / 60 ))m $(( TOTAL_TIME % 60 ))s)"
echo ""

# Output files
echo "Output files:"
ls -lh "${OUTDIR}/"
echo ""

# gVCF stats
echo "gVCF stats (first 30 lines):"
bcftools stats "${OUTDIR}/${SAMPLE_ID}.g.vcf.gz" | head -30

echo ""
echo "============================================"
echo " Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"
