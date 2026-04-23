# NEA-EHI Mosquito WGS Pipeline

A reproducible whole-genome sequencing (WGS) pipeline for *Aedes aegypti* mosquitoes, using GATK best practices. Supports deployment on both **EC2** and **AWS HealthOmics Private Workflows**.

## Pipeline Overview

```
FASTQ (R1/R2)
  ├── FastQC (quality report)
  └── FastP (trimming: Q20, min 50bp)
        └── BWA-mem2 (alignment to AaegL5)
              └── samtools sort & index
                    └── GATK MarkDuplicates
                          └── GATK HaplotypeCaller (per-sample gVCF)
                                └── [Joint Genotyping: GenomicsDBImport → GenotypeGVCFs → Filter]
```

## Reference

- **Genome:** AaegL5.0 (*Aedes aegypti*, GCF_002204515.2, 1.279 Gb)
- **Paper:** Nature Communications 2025, doi:10.1038/s41467-025-62693-y
- **Samples:** NCBI SRA BioProject [PRJNA318737](https://www.ncbi.nlm.nih.gov/bioproject/PRJNA318737)

## Repository Structure

```
.
├── README.md
├── cloudformation/
│   ├── deploy.sh                     # Stack deploy/manage script
│   ├── wgs-pipeline-stack.yaml       # CloudFormation template (EC2 + S3 + IAM)
│   └── scripts/
│       ├── 01_prepare_reference.sh   # Reference genome indexing
│       ├── 02_simulate_reads.sh      # Test data generation (wgsim)
│       ├── 03_run_per_sample.sh      # Per-sample pipeline
│       ├── 04_joint_genotyping.sh    # Joint genotyping
│       └── 05_run_full_test.sh       # End-to-end test runner
├── workflows/
│   └── gatk/
│       ├── Dockerfile                # Docker image (GATK 4.5 + BWA-mem2 + tools)
│       ├── gatk-mosquito.wdl         # Per-sample WDL workflow (HealthOmics)
│       ├── joint-genotyping.wdl      # Joint genotyping WDL workflow
│       ├── run-inputs-SRR6063611.json # Example run inputs
│       ├── omics-trust-policy.json   # IAM trust policy for HealthOmics
│       └── omics-permissions-policy.json # IAM permissions policy
├── data-inventory.md                 # S3 data catalog
├── test-results.md                   # EC2 and HealthOmics test results
└── healthomics-performance-report.md # Performance analysis report
```

## Quick Start

### Prerequisites

- AWS CLI v2 configured with appropriate permissions
- Region: ap-northeast-2 (or modify as needed)
- Docker (for building the pipeline image)

### Option 1: EC2 Deployment

```bash
# 1. Deploy CloudFormation stack
cd cloudformation
export VPC_ID=vpc-xxxxxxxxx
export SUBNET_ID=subnet-xxxxxxxxx
./deploy.sh

# 2. Connect to instance
./deploy.sh --connect

# 3. Run the pipeline
cd /home/ec2-user/wgs-pipeline
./scripts/05_run_full_test.sh
```

### Option 2: AWS HealthOmics

```bash
# 1. Build and push Docker image to ECR
aws ecr create-repository --repository-name nea-ehi-gatk --region <REGION>
aws ecr get-login-password --region <REGION> | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com
docker build -t nea-ehi-gatk:latest -f workflows/gatk/Dockerfile .
docker tag nea-ehi-gatk:latest <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/nea-ehi-gatk:latest
docker push <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/nea-ehi-gatk:latest

# 2. Grant HealthOmics access to ECR
aws ecr set-repository-policy --repository-name nea-ehi-gatk \
  --policy-text file://workflows/gatk/omics-ecr-policy.json --region <REGION>

# 3. Create IAM role for HealthOmics
aws iam create-role --role-name nea-ehi-omics-workflow-role \
  --assume-role-policy-document file://workflows/gatk/omics-trust-policy.json
aws iam put-role-policy --role-name nea-ehi-omics-workflow-role \
  --policy-name omics-permissions \
  --policy-document file://workflows/gatk/omics-permissions-policy.json

# 4. Register workflow
cd workflows/gatk
zip gatk-mosquito-workflow.zip gatk-mosquito.wdl
aws omics create-workflow --name gatk-mosquito --engine WDL \
  --definition-zip fileb://gatk-mosquito-workflow.zip \
  --main gatk-mosquito.wdl --region <REGION>

# 5. Start run (update run-inputs JSON with your S3 paths first)
aws omics start-run \
  --workflow-id <WORKFLOW_ID> \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/nea-ehi-omics-workflow-role \
  --name "SRR6063611-run" \
  --output-uri s3://<BUCKET>/omics-output/ \
  --parameters file://run-inputs-SRR6063611.json \
  --storage-type DYNAMIC --log-level ALL --region <REGION>
```

## Tool Versions

| Tool | Version |
|---|---|
| GATK | 4.5.0.0 |
| BWA-mem2 | 2.2.1 |
| samtools | 1.20 (GATK base image) |
| BCFtools | 1.20 |
| FastQC | 0.12.1 |
| FastP | latest |

## Test Results

See [test-results.md](test-results.md) for detailed EC2 and HealthOmics run results including timing, gVCF verification, and troubleshooting notes.

## HealthOmics Performance Analysis

See [healthomics-performance-report.md](healthomics-performance-report.md) for a detailed comparison of EC2 vs HealthOmics performance and cost, including root cause analysis of the observed performance gap.

**Summary:** HealthOmics completed the pipeline successfully but was 2.2x slower overall and 49% more expensive per sample compared to EC2 m5.2xlarge. The primary cause is SIMD instruction set availability affecting BWA-mem2 (5.4x slower) and general CPU performance affecting HaplotypeCaller (1.8x slower).

## S3 Data Layout

```
s3://<BUCKET>/
├── raw/               # Raw FASTQ files (per sample)
├── reference/         # Reference genome + indices
│   └── mosquito/AaegL5/
├── results/           # Pipeline outputs (gVCF, VCF, metrics)
│   └── gatk/
├── scripts/           # Pipeline shell scripts
└── omics-output/      # HealthOmics run outputs
```

See [data-inventory.md](data-inventory.md) for the complete data catalog.

## Known Issues

1. **BWA-mem2 on HealthOmics:** 5.4x slower due to SIMD fallback. Consider using `minimap2` or `bwa mem` (v0.7.x) as alternatives.
2. **HealthOmics read-only input paths:** WDL tasks must stage reference files to a writable directory (`/tmp/ref`) before tools that require co-located index files.
3. **BWA-mem2 symlink resolution:** Must invoke via full path (`/opt/bwa-mem2-2.2.1_x64-linux/bwa-mem2`) to ensure correct SIMD binary selection.
