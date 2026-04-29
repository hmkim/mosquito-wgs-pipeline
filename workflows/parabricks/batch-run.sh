#!/bin/bash
set -euxo pipefail

BUCKET="nea-ehi-wgs-data-664263524008-ap-northeast-2"
SAMPLE="SRR6063611"
WORKDIR="/local_disk"

mkdir -p ${WORKDIR}/tmp_fq2bam

echo "=== Downloading input data ==="
aws s3 cp s3://${BUCKET}/reference/mosquito/AaegL5/AaegL5.fasta.tar ${WORKDIR}/
aws s3 cp s3://${BUCKET}/raw/mosquito-wgs/${SAMPLE}/${SAMPLE}_R1.fastq.gz ${WORKDIR}/
aws s3 cp s3://${BUCKET}/raw/mosquito-wgs/${SAMPLE}/${SAMPLE}_R2.fastq.gz ${WORKDIR}/

echo "=== Extracting reference ==="
cd ${WORKDIR}
tar xf AaegL5.fasta.tar

echo "=== Running fq2bam ==="
time pbrun fq2bam \
  --ref AaegL5.fasta \
  --in-fq ${SAMPLE}_R1.fastq.gz ${SAMPLE}_R2.fastq.gz \
  "@RG\tID:${SAMPLE}\tLB:lib1\tPL:ILLUMINA\tSM:${SAMPLE}\tPU:unit1" \
  --out-bam ${SAMPLE}.pb.bam \
  --tmp-dir ${WORKDIR}/tmp_fq2bam \
  --low-memory

echo "=== Running haplotypecaller ==="
time pbrun haplotypecaller \
  --ref AaegL5.fasta \
  --in-bam ${SAMPLE}.pb.bam \
  --out-variants ${SAMPLE}.g.vcf \
  --gvcf

echo "=== Uploading results ==="
aws s3 cp ${SAMPLE}.pb.bam s3://${BUCKET}/output/parabricks-batch/${SAMPLE}/
aws s3 cp ${SAMPLE}.pb.bam.bai s3://${BUCKET}/output/parabricks-batch/${SAMPLE}/
aws s3 cp ${SAMPLE}.g.vcf s3://${BUCKET}/output/parabricks-batch/${SAMPLE}/

echo "=== Done ==="
