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
│       ├── 03_run_per_sample.sh      # Per-sample pipeline (BWA-mem2)
│       ├── 04_joint_genotyping.sh    # Joint genotyping
│       └── 05_run_full_test.sh       # End-to-end test runner
├── workflows/
│   ├── gatk/                         # BWA-mem2 variant (original)
│   │   ├── Dockerfile
│   │   ├── gatk-mosquito.wdl         # Per-sample WDL (HealthOmics)
│   │   ├── joint-genotyping.wdl      # Joint genotyping WDL
│   │   ├── run-inputs-SRR6063611.json
│   │   ├── omics-trust-policy.json
│   │   └── omics-permissions-policy.json
│   ├── gatk-bwa/                     # BWA v0.7.x variant (HealthOmics-optimized)
│   │   ├── Dockerfile
│   │   ├── gatk-mosquito-bwa.wdl     # Per-sample WDL using BWA
│   │   ├── run-inputs-SRR6063611.json
│   │   └── README.md
│   └── parabricks/                   # GPU-accelerated variant
│       ├── batch-run.sh              # AWS Batch job script (validated)
│       ├── batch-execution-plan.md   # Batch infrastructure setup
│       ├── gpu-test/gpu-probe.wdl    # GPU acceleratorType probe workflow
│       ├── v6-a10g/                  # HealthOmics WDL (fq2bam + HC)
│       ├── run-parabricks.sh         # Standalone EC2 GPU script
│       └── README.md
├── healthomics-gpu-inquiry.eml       # GPU regional availability inquiry to HealthOmics SA
├── pipeline-analysis-crawford2024.md # Crawford et al. 2024 pipeline comparison
├── data-inventory.md                 # S3 data catalog
├── test-results.md                   # EC2, HealthOmics, and Batch test results
└── healthomics-performance-report.md # Performance analysis report
```

## Pipeline Variants

| Variant | Aligner | Platform | Best For |
|---|---|---|---|
| `workflows/gatk/` | BWA-mem2 v2.2.1 | EC2 (AVX-512), HealthOmics | EC2 with AVX-512 support |
| `workflows/gatk-bwa/` | BWA v0.7.19 | EC2, HealthOmics | Tested; no improvement over BWA-mem2 on HealthOmics |
| `workflows/parabricks/` | Parabricks fq2bam (GPU) | AWS Batch (g5.12xlarge), HealthOmics (omics.g5.12xlarge, us-east-1) | **Recommended** — Batch: 37 min/$3.66, Omics: 45 min/$5.82 |

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

**Summary:**

| Platform | Pipeline Time | Cost/Sample | vs EC2 |
|---|---:|---:|---:|
| EC2 m5.2xlarge (BWA-mem2, CPU) | 12.6h | $7.02 | baseline |
| HealthOmics (BWA-mem2, CPU) | 27.4h | $10.46 | 2.2x slower, +49% |
| HealthOmics (BWA v0.7.19, CPU) | 20.5h | $8.57 | 1.6x slower, +22% |
| **AWS Batch g5.12xlarge (Parabricks, GPU)** | **37 min** | **$4.16** | **20x faster, -41%** |
| **HealthOmics omics.g5.12xlarge (Parabricks, GPU)** | **46 min** | **$5.90** | **16x faster, -16%** |

Parabricks GPU is the clear winner on both platforms. Batch GPU is cheapest ($4.16 OD, Spot ~$1.66); HealthOmics GPU ($5.90) is 42% more than Batch — almost entirely due to 35% higher hourly rate (managed service margin). Both are us-east-1 for HealthOmics GPU (A10G).

## S3 Data Layout

```
s3://<BUCKET>/
├── raw/                          # Raw FASTQ files (per sample)
├── reference/                    # Reference genome + indices (BWA-mem2, BWA, Parabricks tarball)
│   └── mosquito/AaegL5/
├── results/gatk/                 # Simulated data pipeline outputs
├── output/parabricks-batch/      # Parabricks GPU outputs (BAM, gVCF)
├── omics-output/                 # HealthOmics run outputs
└── scripts/                      # Pipeline shell scripts
```

See [data-inventory.md](data-inventory.md) for the complete data catalog.

## Known Issues

1. **BWA-mem2 on HealthOmics:** 5.4x slower due to SIMD fallback (AVX-512 → SSE4.x). BWA v0.7.19 tested but shows identical performance (456 vs 482 min). **Resolved:** Use Parabricks GPU via `workflows/parabricks/` on AWS Batch (37 min) or HealthOmics GPU in us-east-1 (45 min).
2. **HealthOmics read-only input paths:** WDL tasks must stage reference files to a writable directory (`/tmp/ref`) before tools that require co-located index files.
3. **BWA-mem2 symlink resolution:** Must invoke via full path (`/opt/bwa-mem2-2.2.1_x64-linux/bwa-mem2`) to ensure correct SIMD binary selection.
4. **Parabricks GPU VRAM requirement:** HaplotypeCaller needs A10G (24 GiB VRAM) or better — T4 (16 GiB) hits CUDA OOM on *Ae. aegypti* 1.3 Gbp genome. AWS Batch g5.12xlarge and HealthOmics omics.g5.12xlarge (both 4x A10G) are validated.
5. **HealthOmics A10G regional availability:** `nvidia-tesla-a10g` acceleratorType only works in us-east-1. In ap-northeast-2 and ap-southeast-1 it returns `UNSUPPORTED_GPU_INSTANCE_TYPE`. `nvidia-tesla-t4-a10g` always selects T4 (lowest cost) in all tested regions, which is insufficient for HaplotypeCaller. Inquiry sent to HealthOmics team — see `healthomics-gpu-inquiry.eml`.
6. **HealthOmics GPU provisioning latency:** GPU instance provisioning on HealthOmics took ~52 min for Run 1587591 (us-east-1), resulting in 105 min wall-clock for 45 min of compute. This may vary with fleet availability.
