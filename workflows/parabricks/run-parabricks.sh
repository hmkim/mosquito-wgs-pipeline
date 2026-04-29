#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
# run-parabricks.sh
# GPU-accelerated per-sample pipeline using NVIDIA Parabricks
# Usage: ./run-parabricks.sh <sample_id> <fastq_r1> <fastq_r2>
# Requires: NVIDIA GPU (V100/A10G/A100), Docker with NVIDIA Container Toolkit
# ─────────────────────────────────────────────────────────

PARABRICKS_IMAGE="${PARABRICKS_IMAGE:-nvcr.io/nvidia/clara/clara-parabricks:4.3.1-1}"
REF="${REF:-./reference/mosquito/AaegL5/AaegL5.fasta}"
WORKDIR="${WORKDIR:-$(pwd)}"

SAMPLE_ID="${1:?Usage: $0 <sample_id> <fastq_r1> <fastq_r2>}"
FASTQ_R1="${2:?Provide R1 FASTQ path}"
FASTQ_R2="${3:?Provide R2 FASTQ path}"

OUTDIR="${WORKDIR}/results/parabricks/${SAMPLE_ID}"
mkdir -p "${OUTDIR}"

echo "============================================"
echo " Parabricks Pipeline: ${SAMPLE_ID}"
echo " R1: ${FASTQ_R1}"
echo " R2: ${FASTQ_R2}"
echo " Reference: ${REF}"
echo " Start: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

# Pre-flight: verify GPU
echo ""
echo "--- GPU Check ---"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader || {
    echo "[ERROR] No NVIDIA GPU detected. Parabricks requires a GPU."
    exit 1
}

# Pre-flight: verify input files
for f in "${REF}" "${REF}.fai" "${FASTQ_R1}" "${FASTQ_R2}"; do
    if [ ! -f "$f" ]; then
        echo "[ERROR] Required file not found: $f"
        exit 1
    fi
done
echo "[OK] All input files verified"

# ─── Step 1: fq2bam (Alignment + Sort + MarkDuplicates) ───
echo ""
echo "--- Step 1/2: fq2bam (Align + Sort + MarkDup) ---"
STEP_START=$(date +%s)

docker run --rm --gpus all \
    -v "${WORKDIR}:/data" \
    -w /data \
    "${PARABRICKS_IMAGE}" \
    pbrun fq2bam \
        --ref "${REF}" \
        --in-fq "${FASTQ_R1}" "${FASTQ_R2}" \
            "@RG\tID:${SAMPLE_ID}\tSM:${SAMPLE_ID}\tPL:ILLUMINA\tLB:lib1" \
        --out-bam "${OUTDIR}/${SAMPLE_ID}.dedup.bam" \
        --out-duplicate-metrics "${OUTDIR}/${SAMPLE_ID}.dedup_metrics.txt"

STEP1_TIME=$(( $(date +%s) - STEP_START ))
echo "[OK] fq2bam complete"
echo "[TIME] fq2bam: ${STEP1_TIME}s ($(( STEP1_TIME / 60 ))m)"
samtools flagstat "${OUTDIR}/${SAMPLE_ID}.dedup.bam" | head -3

# ─── Step 2: HaplotypeCaller (GPU-accelerated) ───
echo ""
echo "--- Step 2/2: HaplotypeCaller (GPU) ---"
STEP_START=$(date +%s)

docker run --rm --gpus all \
    -v "${WORKDIR}:/data" \
    -w /data \
    "${PARABRICKS_IMAGE}" \
    pbrun haplotypecaller \
        --ref "${REF}" \
        --in-bam "${OUTDIR}/${SAMPLE_ID}.dedup.bam" \
        --out-variants "${OUTDIR}/${SAMPLE_ID}.g.vcf.gz" \
        --gvcf

STEP2_TIME=$(( $(date +%s) - STEP_START ))
echo "[OK] HaplotypeCaller complete"
echo "[TIME] HaplotypeCaller: ${STEP2_TIME}s ($(( STEP2_TIME / 60 ))m)"

# ─── Summary ───
TOTAL_TIME=$(( STEP1_TIME + STEP2_TIME ))
echo ""
echo "============================================"
echo " Pipeline Summary: ${SAMPLE_ID}"
echo "============================================"
echo " fq2bam:          ${STEP1_TIME}s ($(( STEP1_TIME / 60 ))m)"
echo " HaplotypeCaller: ${STEP2_TIME}s ($(( STEP2_TIME / 60 ))m)"
echo " ────────────────────────"
echo " Total:           ${TOTAL_TIME}s ($(( TOTAL_TIME / 60 ))m)"
echo ""

echo "Output files:"
ls -lh "${OUTDIR}/"
echo ""

echo "gVCF verification:"
bcftools stats "${OUTDIR}/${SAMPLE_ID}.g.vcf.gz" | head -30

echo ""
echo "============================================"
echo " Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"
