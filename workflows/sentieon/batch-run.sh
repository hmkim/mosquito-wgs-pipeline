#!/bin/bash
set -euxo pipefail

export SENTIEON_LICENSE="${SENTIEON_LICENSE:-LICENSE_SERVER_IP:8990}"
SAMPLE="${SAMPLE:-SRR6063611}"
BUCKET="${BUCKET:-mosquito-wgs-data}"
WORKDIR="/local_disk"
NPROC=$(nproc)

mkdir -p ${WORKDIR} && cd ${WORKDIR}

echo "=== Start: $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
echo "=== Instance: $(curl -s http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo unknown) ==="
echo "=== CPUs: ${NPROC} ==="

echo "=== Downloading reference ==="
aws s3 cp s3://${BUCKET}/reference/mosquito/AaegL5/AaegL5.fasta.tar .
tar xf AaegL5.fasta.tar
rm -f AaegL5.fasta.tar

echo "=== Downloading FASTQ ==="
aws s3 cp s3://${BUCKET}/raw/mosquito-wgs/${SAMPLE}/${SAMPLE}_R1.fastq.gz .
aws s3 cp s3://${BUCKET}/raw/mosquito-wgs/${SAMPLE}/${SAMPLE}_R2.fastq.gz .

echo "=== Downloading model bundle ==="
aws s3 cp s3://${BUCKET}/sentieon/SentieonIlluminaWGS2.2.bundle .

echo "=== License check ==="
sentieon licclnt ping
sentieon licclnt query DNAscope

echo "=== Running sentieon-cli dnascope ==="
time sentieon-cli dnascope \
  -r AaegL5.fasta \
  -m SentieonIlluminaWGS2.2.bundle \
  --r1_fastq ${SAMPLE}_R1.fastq.gz \
  --r2_fastq ${SAMPLE}_R2.fastq.gz \
  --readgroups "@RG\tID:${SAMPLE}\tSM:${SAMPLE}\tPL:ILLUMINA\tLB:lib1" \
  -t ${NPROC} \
  -g \
  --skip_svs \
  ${SAMPLE}.g.vcf.gz

echo "=== Output files ==="
ls -lh ${SAMPLE}.*

echo "=== Uploading results ==="
OUT_PREFIX="s3://${BUCKET}/output/sentieon-cli-batch/${SAMPLE}"
for f in ${SAMPLE}.g.vcf.gz ${SAMPLE}.g.vcf.gz.tbi ${SAMPLE}.vcf.gz ${SAMPLE}.vcf.gz.tbi \
         ${SAMPLE}.cram ${SAMPLE}.cram.crai ${SAMPLE}.dedup_metrics.txt; do
  [ -f "$f" ] && aws s3 cp "$f" "${OUT_PREFIX}/"
done

echo "=== Done: $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
