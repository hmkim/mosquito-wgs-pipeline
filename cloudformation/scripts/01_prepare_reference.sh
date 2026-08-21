#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
# 01_prepare_reference.sh
# Download Ae. aegypti AaegL5 reference genome and build all indices
# ─────────────────────────────────────────────────────────

WGS_HOME="${WGS_HOME:-/home/ec2-user/wgs-pipeline}"
REF_DIR="${WGS_HOME}/reference/mosquito/AaegL5"
LOG_DIR="${WGS_HOME}/logs"
mkdir -p "${REF_DIR}" "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/01_prepare_reference_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================"
echo " Step 1: Prepare Reference Genome (AaegL5)"
echo " Start: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

# ─── 1.1 Download genome from NCBI ───
if [ ! -f "${REF_DIR}/AaegL5.fasta" ]; then
    echo "[INFO] Downloading AaegL5 reference genome from NCBI..."
    cd /tmp
    datasets download genome accession GCF_002204515.2 \
        --include gff3,rna,cds,protein,genome,seq-report

    unzip -o ncbi_dataset.zip
    NCBI_DATA="/tmp/ncbi_dataset/data/GCF_002204515.2"

    # Copy genome FASTA
    cp "${NCBI_DATA}/GCF_002204515.2_AaegL5.0_genomic.fna" "${REF_DIR}/AaegL5.fasta"
    echo "[OK] Genome FASTA copied: $(du -h ${REF_DIR}/AaegL5.fasta | cut -f1)"

    # Copy GFF3 annotation
    if [ -f "${NCBI_DATA}/genomic.gff" ]; then
        cp "${NCBI_DATA}/genomic.gff" "${REF_DIR}/AaegL5.gff3"
        echo "[OK] GFF3 annotation copied"
    fi

    # Cleanup
    rm -rf /tmp/ncbi_dataset /tmp/ncbi_dataset.zip /tmp/README.md
else
    echo "[SKIP] AaegL5.fasta already exists"
fi

# ─── 1.2 Build samtools faidx (.fai) ───
if [ ! -f "${REF_DIR}/AaegL5.fasta.fai" ]; then
    echo "[INFO] Building samtools faidx index..."
    samtools faidx "${REF_DIR}/AaegL5.fasta"
    echo "[OK] FASTA index created"
else
    echo "[SKIP] .fai index already exists"
fi

# ─── 1.3 Build GATK sequence dictionary (.dict) ───
if [ ! -f "${REF_DIR}/AaegL5.dict" ]; then
    echo "[INFO] Creating GATK sequence dictionary..."
    gatk CreateSequenceDictionary -R "${REF_DIR}/AaegL5.fasta"
    echo "[OK] Sequence dictionary created"
else
    echo "[SKIP] .dict already exists"
fi

# ─── 1.4 Build BWA-mem2 index ───
if [ ! -f "${REF_DIR}/AaegL5.fasta.bwt.2bit.64" ]; then
    echo "[INFO] Building BWA-mem2 index (this takes 30-60 min, ~80 GB RAM)..."
    echo "[INFO] Start indexing: $(date -u '+%H:%M:%S UTC')"
    bwa-mem2 index "${REF_DIR}/AaegL5.fasta"
    echo "[OK] BWA-mem2 index complete: $(date -u '+%H:%M:%S UTC')"
else
    echo "[SKIP] BWA-mem2 index already exists"
fi

# ─── 1.5 Verification ───
echo ""
echo "============================================"
echo " Verification"
echo "============================================"

EXPECTED_FILES=(
    "AaegL5.fasta"
    "AaegL5.fasta.fai"
    "AaegL5.dict"
    "AaegL5.fasta.0123"
    "AaegL5.fasta.amb"
    "AaegL5.fasta.ann"
    "AaegL5.fasta.bwt.2bit.64"
    "AaegL5.fasta.pac"
)

ALL_OK=true
for f in "${EXPECTED_FILES[@]}"; do
    if [ -f "${REF_DIR}/${f}" ]; then
        SIZE=$(du -h "${REF_DIR}/${f}" | cut -f1)
        echo "[OK] ${f}  (${SIZE})"
    else
        echo "[FAIL] ${f} — MISSING"
        ALL_OK=false
    fi
done

echo ""
echo "--- Chromosome info (top 5 from .fai) ---"
head -5 "${REF_DIR}/AaegL5.fasta.fai"

echo ""
echo "--- Sequence dictionary (top 5) ---"
head -5 "${REF_DIR}/AaegL5.dict"

if $ALL_OK; then
    echo ""
    echo "[SUCCESS] All reference files ready."
else
    echo ""
    echo "[ERROR] Some files missing. Check logs above."
    exit 1
fi

# ─── 1.6 Upload to S3 (optional) ───
if [ -n "${DATA_BUCKET:-}" ]; then
    echo ""
    echo "[INFO] Syncing reference to S3: s3://${DATA_BUCKET}/reference/mosquito/AaegL5/"
    aws s3 sync "${REF_DIR}/" "s3://${DATA_BUCKET}/reference/mosquito/AaegL5/" \
        --exclude "*.gff3"
    echo "[OK] S3 sync complete"
fi

echo ""
echo "============================================"
echo " Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"
