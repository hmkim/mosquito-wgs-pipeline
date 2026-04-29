# Test Plan — BWA v0.7.x Pipeline on HealthOmics

**Date:** 2026-04-23
**Objective:** Test the BWA v0.7.x variant of the per-sample pipeline on AWS HealthOmics and compare alignment performance against the BWA-mem2 baseline.
**Sample:** SRR6063611 (*Ae. aegypti*, 98M read pairs, NextSeq 500, ~23x coverage)
**Reference:** AaegL5 (GCF_002204515.2, 1.279 Gb)

---

## 1. Rationale

BWA-mem2 exhibited a **5.4x slowdown** on HealthOmics compared to EC2, caused by SIMD instruction set degradation (AVX-512 → SSE4.x fallback). BWA v0.7.x has minimal SIMD dependency (SSE2 only), so its performance should be **consistent across CPU architectures**.

This test validates that hypothesis and measures the actual improvement.

### Expected Outcome

| Metric | BWA-mem2 (HealthOmics) | BWA v0.7.x (expected) |
|---|---|---|
| Alignment time | 482 min (8.0h) | ~90-150 min |
| Total pipeline | 1,642 min (27.4h) | ~1,200-1,300 min (~20-22h) |
| Alignment output | Identical | Identical |

---

## 2. Pre-requisites

### 2.1 Generate BWA v0.7.x Index

BWA v0.7.x uses a different index format from BWA-mem2. Required files: `.bwt`, `.ann`, `.amb`, `.pac`, `.sa`.

The `.ann`, `.amb`, `.pac` files are shared with BWA-mem2 (already in S3). Two additional files are needed: `.bwt` and `.sa`.

```bash
# On EC2 instance with reference genome
cd /home/ec2-user/wgs-pipeline/reference/mosquito/AaegL5

# Install BWA v0.7.18 (if not already installed)
cd /tmp
wget -qO- https://github.com/lh3/bwa/releases/download/v0.7.18/bwa-0.7.18.tar.bz2 | tar -xjf -
cd bwa-0.7.18 && make -j$(nproc) && sudo cp bwa /usr/local/bin/bwa

# Generate BWA index (takes ~30-60 min, ~6 GB RAM)
cd /home/ec2-user/wgs-pipeline/reference/mosquito/AaegL5
bwa index AaegL5.fasta

# Verify output files
ls -lh AaegL5.fasta.{bwt,ann,amb,pac,sa}
# Expected:
#   AaegL5.fasta.bwt  ~2.6 GB   (NEW — BWA specific)
#   AaegL5.fasta.ann  ~100 KB   (shared with BWA-mem2)
#   AaegL5.fasta.amb  <1 KB     (shared with BWA-mem2)
#   AaegL5.fasta.pac  ~650 MB   (shared with BWA-mem2)
#   AaegL5.fasta.sa   ~1.3 GB   (NEW — BWA specific)

# Upload NEW files to S3
aws s3 cp AaegL5.fasta.bwt s3://<BUCKET>/reference/mosquito/AaegL5/
aws s3 cp AaegL5.fasta.sa  s3://<BUCKET>/reference/mosquito/AaegL5/
```

### 2.2 Build and Push Docker Image

```bash
cd /home/ec2-user/project-NEA-EHI/workflows/gatk-bwa

# Build
docker build -t nea-ehi-gatk-bwa:latest .

# Tag and push to ECR
aws ecr create-repository --repository-name nea-ehi-gatk-bwa --region <REGION>
aws ecr get-login-password --region <REGION> | \
  docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com
docker tag nea-ehi-gatk-bwa:latest \
  <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/nea-ehi-gatk-bwa:latest
docker push <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/nea-ehi-gatk-bwa:latest

# Grant HealthOmics access
aws ecr set-repository-policy --repository-name nea-ehi-gatk-bwa \
  --policy-text '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "omics",
      "Effect": "Allow",
      "Principal": {"Service": "omics.amazonaws.com"},
      "Action": ["ecr:GetDownloadUrlForLayer","ecr:BatchGetImage","ecr:BatchCheckLayerAvailability"],
      "Condition": {"StringEquals": {"aws:SourceAccount": "<ACCOUNT_ID>"}}
    }]
  }' --region <REGION>
```

### 2.3 Register HealthOmics Workflow

```bash
cd /home/ec2-user/project-NEA-EHI/workflows/gatk-bwa
zip gatk-mosquito-bwa-workflow.zip gatk-mosquito-bwa.wdl

aws omics create-workflow \
  --name gatk-mosquito-bwa \
  --engine WDL \
  --definition-zip fileb://gatk-mosquito-bwa-workflow.zip \
  --main gatk-mosquito-bwa.wdl \
  --region <REGION>

# Record the workflow ID: __________
```

### 2.4 Update run-inputs JSON

Edit `run-inputs-SRR6063611.json` with actual S3 paths and ECR URI.

---

## 3. Execution

### 3.1 Start HealthOmics Run

```bash
aws omics start-run \
  --workflow-id <WORKFLOW_ID> \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/nea-ehi-omics-workflow-role \
  --name "SRR6063611-bwa-v1" \
  --output-uri s3://<BUCKET>/omics-output/ \
  --parameters file://run-inputs-SRR6063611.json \
  --storage-type DYNAMIC \
  --log-level ALL \
  --region <REGION>

# Record the run ID: __________
```

### 3.2 Monitor Progress

```bash
# Check run status
aws omics get-run --id <RUN_ID> --region <REGION> \
  --query '{status:status,startTime:startTime,stopTime:stopTime}'

# List task statuses
aws omics list-run-tasks --id <RUN_ID> --region <REGION> \
  --query 'items[].{name:name,status:status,cpus:cpus,memory:memory,startTime:startTime,stopTime:stopTime}'
```

---

## 4. Validation

### 4.1 Performance Comparison (actual results — Run ID: 6503897)

| Task | BWA-mem2 (baseline) | BWA v0.7.x (actual) | Ratio |
|---|---|---|---|
| FastQC | 18 min | 18 min | 1.0x |
| FastP | 12 min | 18 min | 1.5x |
| **BwaAlign** | **482 min** | **456 min** | **0.95x** |
| SortAndIndex | 16 min | 23 min | 1.4x |
| MarkDuplicates | 34 min | 35 min | 1.0x |
| HaplotypeCaller | 1,080 min | 680 min | 0.63x |
| **Total** | **1,642 min** | **1,230 min** | **0.75x** |

### 4.2 Output Correctness

```bash
# Download gVCF from HealthOmics output
aws s3 cp s3://<BUCKET>/omics-output/<RUN_ID>/out/gvcf ./bwa_gvcf/

# Compare gVCF metrics against BWA-mem2 baseline
bcftools stats bwa_gvcf/SRR6063611.g.vcf.gz | grep "^SN"

# Spot-check variant concordance on chr1 first 1 Mb
bcftools view -r NC_035107.1:1-1000000 -v snps bwa_gvcf/SRR6063611.g.vcf.gz | \
  bcftools stats - | grep "^SN"

# Compare with BWA-mem2 gVCF (already in S3 from previous run)
# SNP count in chr1:1-1Mb should be similar (~650)
```

### 4.3 Alignment Statistics

```bash
# From HealthOmics output BAM (if available) or gVCF header
samtools flagstat <dedup_bam>
# Mapping rate should be >90% and similar to BWA-mem2 run
```

### 4.4 Cost Calculation (actual)

| Component | BWA-mem2 run | BWA v0.7.x run |
|---|---|---|
| Compute | $10.09 | $8.04 |
| Storage | $0.37 | $0.53 |
| **Total** | **$10.46** | **$8.57** |

The lower total cost is driven by HC's shorter runtime (fleet variability), not alignment improvement.

---

## 5. Success Criteria

| Criterion | Target | Rationale |
|---|---|---|
| BwaAlign time | < 200 min | At least 2x faster than BWA-mem2 HealthOmics run |
| Total pipeline time | < 1,400 min | Meaningful improvement over 1,642 min baseline |
| Per-sample cost | < $9.00 | Below BWA-mem2 HealthOmics cost ($10.46) |
| gVCF variant count | Within 5% of BWA-mem2 | Alignment differences should be negligible |
| Mapping rate | > 90% | Same as BWA-mem2 baseline |

---

## 6. Decision Matrix (post-test) — RESOLVED

**Outcome: BwaAlign 456 min (> 300 min threshold) — hypothesis disproven.**

| Result | Next Step | Status |
|---|---|---|
| ~~BwaAlign < 150 min~~ | ~~Adopt BWA v0.7.x~~ | Not met |
| ~~BwaAlign 150-300 min~~ | ~~BWA v0.7.x preferred~~ | Not met |
| **BwaAlign > 300 min** | **Investigate further** | **Actual: 456 min** |
| **Final recommendation** | **Use Parabricks GPU (37 min total via AWS Batch g5.12xlarge)** | **Validated** |

---

## 7. Optional: EC2 Comparison Run

For a complete 3-way comparison, also run BWA v0.7.x on EC2:

```bash
# On EC2 m5.2xlarge
bwa mem \
  -t 8 \
  -R "@RG\tID:SRR6063611\tSM:SRR6063611\tPL:ILLUMINA\tLB:lib1" \
  reference/mosquito/AaegL5/AaegL5.fasta \
  results/gatk/SRR6063611/SRR6063611_trimmed_R1.fastq.gz \
  results/gatk/SRR6063611/SRR6063611_trimmed_R2.fastq.gz \
| samtools view -bS -@ 2 - > results/gatk/SRR6063611/SRR6063611.bwa.aligned.bam
```

This establishes whether BWA v0.7.x on HealthOmics matches BWA v0.7.x on EC2 (validating the SIMD-independence hypothesis).
