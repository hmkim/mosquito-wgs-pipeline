# Mosquito WGS Pipeline

A reproducible whole-genome sequencing (WGS) pipeline for *Aedes aegypti* mosquitoes. Supports 4 variant callers across 3 AWS platforms: **EC2**, **AWS Batch**, and **AWS HealthOmics**.

## Pipeline Overview

```
FASTQ (R1/R2)
  │
  ├─── GATK Path (EC2 / HealthOmics) ───────────────────────────────────────┐
  │    FastQC → FastP → BWA-mem2 → sort → MarkDuplicates → HaplotypeCaller  │
  │                                                          → gVCF         │
  ├─── Sentieon Path (Batch / HealthOmics) ─────────────────────────────────┤
  │    sentieon-cli dnascope (BWA + sort + dedup + call + ModelApply)        │
  │      or WDL v4: single SentieonGermline task (same stages, one instance) │
  │                                                          → gVCF         │
  ├─── Parabricks Path (Batch / HealthOmics GPU) ──────────────────────────┤
  │    fq2bam (GPU-BWA + sort + dedup) → HaplotypeCaller (GPU)              │
  │                                                          → gVCF         │
  └─── Joint Genotyping ────────────────────────────────────────────────────┘
       GenomicsDBImport → GenotypeGVCFs → Filter
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
│   ├── sentieon-license-server-stack.yaml  # Sentieon license server CFN
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
│   ├── parabricks/                   # GPU-accelerated variant
│   │   ├── batch-run.sh              # AWS Batch job script (g5.12xlarge)
│   │   ├── batch-execution-plan.md   # Batch infrastructure setup
│   │   ├── gpu-test/gpu-probe.wdl    # GPU acceleratorType probe workflow
│   │   ├── v5-nvidia-match/          # HealthOmics WDL (nvidia-match)
│   │   ├── v6-a10g/                  # HealthOmics WDL (A10G)
│   │   ├── v8-use1-a10g/            # HealthOmics WDL (us-east-1, A10G)
│   │   ├── v9-t4-a10g-l4/          # HealthOmics WDL (nvidia-t4-a10g-l4, L4)
│   │   ├── run-parabricks.sh         # Standalone EC2 GPU script
│   │   └── README.md
│   ├── sentieon/                     # Sentieon DNAscope variant
│   │   ├── Dockerfile
│   │   ├── deploy-sentieon.sh        # License server + workflow deployment
│   │   ├── batch-run.sh              # AWS Batch job script (c7i.8xlarge)
│   │   ├── sentieon-dnascope-mosquito-v4.wdl  # Single-task WDL (default, 109 min/$3.41)
│   │   ├── run-inputs-SRR6063611-v4.json
│   │   ├── sentieon-dnascope-mosquito.wdl  # Original two-task WDL
│   │   ├── run-inputs-SRR6063611.json
│   │   └── README.md
│   ├── radseq/                       # RADseq pipeline (Nextflow)
│   │   ├── Dockerfile
│   │   ├── main.nf
│   │   └── nextflow.config
│   └── simulation/                   # Stochastic simulation
│       ├── Dockerfile
│       ├── run_simulation.R
│       └── run_simulation.jl
├── run-1587591-timeline.svg          # HealthOmics GPU run timeline
└── wgs-benchmark-findings.md         # Consolidated benchmark findings and limitations
```

## Pipeline Variants

| Variant | Aligner | Platform | Region | Best For |
|---|---|---|---|---|
| `workflows/gatk/` | BWA-mem2 v2.2.1 | EC2, HealthOmics | ap-northeast-2 | EC2 with AVX-512 support |
| `workflows/gatk-bwa/` | BWA v0.7.19 | EC2, HealthOmics | ap-northeast-2 | Compatibility; no improvement over BWA-mem2 on HealthOmics |
| `workflows/parabricks/` | Parabricks fq2bam (GPU) | Batch, HealthOmics | ap-northeast-2, us-east-1 | **Fastest** — Batch: 44 min/$5.12, Omics: 105 min/$5.90 |
| `workflows/sentieon/` (WDL v4) | Sentieon DNAscope (CPU) | HealthOmics | ap-southeast-1 | **Best managed** — 109 min/$3.41 (single task, DYNAMIC) |
| `workflows/sentieon/` (Batch) | sentieon-cli dnascope (CPU) | Batch | ap-southeast-1 | Cheapest — 97 min/$2.67, but emitted a variant-only VCF (see Known Issues #14) |

## Quick Start

### Prerequisites

- AWS CLI v2 configured with appropriate permissions
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
aws ecr create-repository --repository-name mosquito-wgs-gatk --region <REGION>
aws ecr get-login-password --region <REGION> | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com
docker build -t mosquito-wgs-gatk:latest -f workflows/gatk/Dockerfile .
docker tag mosquito-wgs-gatk:latest <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/mosquito-wgs-gatk:latest
docker push <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/mosquito-wgs-gatk:latest

# 2. Grant HealthOmics access to ECR
aws ecr set-repository-policy --repository-name mosquito-wgs-gatk \
  --policy-text file://workflows/gatk/omics-ecr-policy.json --region <REGION>

# 3. Create IAM role for HealthOmics
aws iam create-role --role-name mosquito-wgs-omics-workflow-role \
  --assume-role-policy-document file://workflows/gatk/omics-trust-policy.json
aws iam put-role-policy --role-name mosquito-wgs-omics-workflow-role \
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
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/mosquito-wgs-omics-workflow-role \
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
| Sentieon | 202503.03 (sentieon-cli 1.6.2) |
| Parabricks | 4.3.1-1 |

## Performance Summary

All costs verified via the AWS Pricing API; HealthOmics compute and storage rates re-verified
2026-08-21. Full stage-by-stage analysis, platform findings, corrections, and known limitations are
consolidated in [`wgs-benchmark-findings.md`](wgs-benchmark-findings.md).

| # | Platform | Region | Pipeline Time | Cost/Sample | Notes |
|---|---|---|---:|---:|---|
| 7 | **Batch c7i.8xlarge (Sentieon-cli, CPU)** | ap-southeast-1 | **97 min** | **$2.67** | Cheapest, but output was variant-only VCF (#14) |
| 10 | **HealthOmics (Sentieon WDL v4, DYNAMIC)** | ap-southeast-1 | **109 min** | **$3.41** | **Best managed** — single task; 95 min compute ≈ Batch parity |
| 8a | HealthOmics (Sentieon WDL v2, DYNAMIC) | ap-southeast-1 | 119 min | $3.69 | Fix #1+#4 (BWA model) |
| 9a | HealthOmics (Sentieon WDL v3, DYNAMIC) | ap-southeast-1 | 162 min | $4.04 | Fix #2+#3+#5 applied |
| 9b | HealthOmics (Sentieon WDL v3, DYNAMIC) | ap-southeast-1 | 162 min | $4.01 | Rerun (reproducibility) |
| 8b | HealthOmics (Sentieon WDL v2, STATIC) | ap-southeast-1 | 123 min | $4.33 | Fix #1+#4, STATIC 1,200 GiB |
| 6 | HealthOmics (Sentieon baseline, DYNAMIC) | ap-southeast-1 | 142 min | $4.44 | Before optimization |
| 4 | **Batch g5.12xlarge (Parabricks, GPU)** | ap-northeast-2 | **44 min** | **$5.12** | **Fastest overall** |
| 5 | HealthOmics omics.g5.12xlarge (Parabricks, GPU) | us-east-1 | 105 min | $5.90 | us-east-1 only (A10G) |
| 1 | EC2 m5.2xlarge (BWA-mem2, CPU) | ap-northeast-2 | 12.6h | $5.93 | Baseline |
| 3 | HealthOmics (GATK + BWA v0.7.19, CPU) | ap-northeast-2 | 20.6h | $9.19 | SIMD fallback |
| 2 | HealthOmics (GATK + BWA-mem2, CPU) | ap-northeast-2 | 27.4h | $11.71 | SIMD fallback, slowest |

## S3 Data Layout

```
s3://<BUCKET>/
├── raw/                          # Raw FASTQ files (per sample)
├── reference/                    # Reference genome + indices
│   └── mosquito/AaegL5/
├── results/gatk/                 # Pipeline outputs
├── output/parabricks-batch/      # Parabricks GPU outputs (BAM, gVCF)
├── omics-output/                 # HealthOmics run outputs
└── scripts/                      # Pipeline shell scripts
```

## Known Issues

1. **BWA-mem2 on HealthOmics:** 5.4x slower due to SIMD fallback (AVX-512 → SSE4.x). **Resolved:** Use Sentieon on Batch ($2.67) or Parabricks GPU on Batch ($5.12).
2. **HealthOmics read-only input paths:** WDL tasks must stage reference files to a writable directory (`/tmp/ref`) before tools that require co-located index files.
3. **BWA-mem2 symlink resolution:** Must invoke via full path (`/opt/bwa-mem2-2.2.1_x64-linux/bwa-mem2`) to ensure correct SIMD binary selection.
4. **Parabricks GPU VRAM requirement:** HaplotypeCaller needs A10G (24 GiB VRAM) or better — T4 (16 GiB) hits CUDA OOM on *Ae. aegypti* 1.3 Gbp genome.
5. **HealthOmics A10G regional availability:** `nvidia-tesla-a10g` acceleratorType only works in us-east-1. Use `nvidia-t4-a10g-l4` for L4 in ap-northeast-2, but ap-southeast-1 only gets T4 (OOM).
6. **HealthOmics GPU provisioning latency:** omics.g5.12xlarge provisioning takes ~54 min, resulting in 105 min wall-clock for 46 min of compute.
7. **Sentieon DNAModelApply .so co-location:** HealthOmics/miniwdl downloads each WDL `File` input to a separate `_miniwdl_inputs/N/` directory. The native `dnascope.model-x86_64.so` must be adjacent to `dnascope.model`, otherwise it falls back to Python inference (37 min vs 5 min). Fixed via `realpath` guard in WDL.
8. **HealthOmics DYNAMIC vs STATIC storage:** DYNAMIC ($0.0004932/GiB-hr) is cheaper than STATIC ($0.0002301/GiB-hr, min 1,200 GiB) for pipelines with <560 GiB storage footprint. Sentieon DNAscope peaks at 64–67 GiB depending on WDL version → DYNAMIC $0.06 vs STATIC $0.57.
9. **Sentieon license expiry:** Current test license (`AWS_Amazon_Services_omics_test.lic`) expires **2026-05-31**. Production license required for continued use.
10. **Parabricks trimming bias:** Parabricks fq2bam does not include adapter trimming. Without FastP pre-processing, produces 9.6M false-positive variants (Ti/Tv 0.43). Shared-site genotype concordance remains 100%.
11. **HealthOmics CPU heterogeneity:** HealthOmics assigns different CPU generations (Skylake 8124M, Cascade Lake 8275CL, Ice Lake 8375C) for the same `omics.c.*` instance type. Skylake exposes 36 threads for a 32 vCPU request; Ice Lake gives exactly 32. This explains the 33 vs 41 min alignment difference between Runs 8a/8b (both using BWA model). Without BWA model, alignment takes 78–83 min regardless of CPU generation. Expect ~20% run-to-run variance on the alignment stage with identical inputs.
12. **GATK cost is not architecture-bound:** the $11.71 GATK-on-HealthOmics figure reflects an unoptimized resource request, not a platform ceiling. BwaAlign is a genuine SIMD penalty (482 min vs ~90 min at the same 8 vCPU), but HaplotypeCaller — $5.27 of the $11.71 — simply ran on 4 vCPU against EC2's 8, which is near-linear scaling rather than a HealthOmics deficit. Raising that task's `cpu` request is untested and should be done before quoting $11.71 for planning.
13. **Benchmark scope is a single sample:** every configuration in the Performance Summary ran SRR6063611. Between-sample variance is unmeasured, and joint genotyping (`workflows/gatk/joint-genotyping.wdl`) has never been executed, so no cohort-level cost exists. Treat per-sample figures as per-sample only.
14. **Batch and HealthOmics did not emit the same artifact:** the Batch output (`output/sentieon-cli-batch/SRR6063611.g.vcf.gz`, 203 MiB) is a **variant-only VCF** despite the `.g.vcf.gz` name and `batch-run.sh`'s `-g` flag — it has no `##ALT=<ID=NON_REF>` or `##GVCFBlock` headers and its first record is a called variant at position 8,646. HealthOmics v4 emitted a full 10.6 GiB gVCF plus a 9.0 GiB CRAM. The Batch CRAM was never uploaded because `batch-run.sh` guards each upload with `[ -f "$f" ]`, which skips missing files silently. Runtime measurements are unaffected, but **$2.67 and $3.41 are not a like-for-like output comparison** — verify the emitted artifact before quoting the Batch figure.
