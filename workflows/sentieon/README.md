# Sentieon DNAscope — Ae. aegypti WGS on AWS HealthOmics

Sentieon DNAscope germline variant calling pipeline for mosquito whole-genome sequencing,
running as an AWS HealthOmics private workflow with VPC-based license server.

## Architecture

- **License Server**: t3.medium EC2 in VPC, running `sentieon licsrvr` on port 8990
- **HealthOmics Workflow**: WDL pipeline using VPC networking (`--network-configuration`)
- **Pipeline**: Sentieon BWA → sort → LocusCollector → Dedup → DNAscope → DNAModelApply (gVCF/CRAM)

## Workflow Versions

| Version | Structure | Wall-clock | Cost/sample |
|---------|-----------|-----------:|------------:|
| **v4** (default) | Single task, BWA/DNAscope models, NUMA + igzip, native CRAM | **109 min** | **$3.41** |
| v1 | Two tasks (alignment, then dedup + calling), no models | 142 min | $4.44 |

v4 is selected by default. Set `WDL_VERSION=v1` to deploy the original two-task workflow.
Consolidating to a single task is what brought HealthOmics to compute-time parity with AWS Batch
(95 min vs 97 min) — see `wgs-benchmark-findings.md` in the repository root.

## Prerequisites

- AWS CLI v2 configured with `ap-southeast-1` region
- Docker (for image build)
- VPC ID, Subnet ID, VPC CIDR of the target VPC
- Sentieon license file (obtained from Sentieon Support)

## Setup Steps

### Step 1 — Deploy License Server

```bash
export VPC_ID=vpc-xxxxx
export SUBNET_ID=subnet-xxxxx
export VPC_CIDR=10.0.0.0/16

./deploy-sentieon.sh --license-stack
```

Note the **Private IP** in the output — send it to Sentieon Support to obtain a license file.

### Step 2 — Install License File

After receiving the `.lic` file from Sentieon:

```bash
# Upload to S3
aws s3 cp Sentieon_mosquito-wgs.lic \
  s3://<BUCKET>/sentieon/

# Start the daemon
./deploy-sentieon.sh --start-license
```

### Step 3 — Build Container Image

```bash
./deploy-sentieon.sh --build-image
```

### Step 4 — Setup IAM and Register Workflow

```bash
./deploy-sentieon.sh --setup-iam
./deploy-sentieon.sh --register          # registers v4 by default

# To register the original two-task workflow instead:
WDL_VERSION=v1 ./deploy-sentieon.sh --register
```

Each version registers under its own workflow name (`sentieon-dnascope-mosquito-v4` / `-v1`) and
caches its ID in `.workflow-id.<version>`, so both can coexist in the account.

### Step 5 — Submit Test Run

```bash
./deploy-sentieon.sh --run
```

`--run` uses the same `WDL_VERSION` as `--register`, so pass it consistently across both commands.

### Step 6 — Monitor

```bash
./deploy-sentieon.sh --status

# Or directly:
aws omics get-run --id <RUN_ID> --region ap-southeast-1
aws omics list-run-tasks --id <RUN_ID> --region ap-southeast-1
```

## Cost Management

The license server costs ~$0.04/hr ($30/month) when running. To save costs:

```bash
# Stop when not running workflows
./deploy-sentieon.sh --stop-license

# Restart before running workflows
./deploy-sentieon.sh --start-license
```

## Files

| File | Description |
|------|-------------|
| `sentieon-dnascope-mosquito-v4.wdl` | **WDL workflow v4 (default)** — single task, BWA/DNAscope models |
| `run-inputs-SRR6063611-v4.json` | Test run parameters for v4 |
| `sentieon-dnascope-mosquito.wdl` | WDL workflow v1 (BWA → Dedup → DNAscope) |
| `run-inputs-SRR6063611.json` | Test run parameters for v1 |
| `Dockerfile` | Container image (amazonlinux:2 + Sentieon 202503.03) |
| `deploy-sentieon.sh` | Deployment and management script |
| `batch-run.sh` | AWS Batch alternative using `sentieon-cli dnascope` |
| `omics-permissions-policy.json` | HealthOmics IAM permissions |
| `omics-ecr-policy.json` | ECR repository policy for HealthOmics |

## Measured Performance

Sample SRR6063611 (*Ae. aegypti*, ~98M read pairs, ~23× coverage). Costs recomputed from run
timestamps × API-verified rates.

| Pipeline | Platform | Time | Cost |
|----------|----------|-----:|-----:|
| `sentieon-cli dnascope` | AWS Batch c7i.8xlarge | 97 min | **$2.67** |
| **Sentieon DNAscope v4** | **HealthOmics** | **109 min** | **$3.41** |
| Sentieon DNAscope v1 | HealthOmics | 142 min | $4.44 |
| Parabricks GPU | AWS Batch g5.12xlarge | 44 min | $5.12 |
| GATK (BWA-mem2) | HealthOmics | 27.4 h | $11.71 |

The GATK figure reflects an unoptimised resource request — its HaplotypeCaller task ran on 4 vCPU.
Do not treat $11.71 as GATK's floor on HealthOmics.

## Notes

- Two model files drive most of the v4 gain: the BWA model roughly halves alignment time
  (78 → 33 min), and DNAscope's model refines variant quality via `DNAModelApply`.
- `DNAModelApply` needs its native `.so` **adjacent to the model file**, but HealthOmics (miniwdl)
  localises each WDL `File` input into a separate directory. The v4 WDL symlinks the library next to
  the model at task start; without it the task falls back to Python and takes 37 min instead of 5.3.
- Use `DYNAMIC` run storage. This pipeline peaks at 64 GiB, far below the ~560 GiB breakeven where
  `STATIC` (1,200 GiB minimum) becomes cheaper — $0.06 versus $0.57 on the storage line.
- HealthOmics does not guarantee a CPU generation for a given `omics.c.*` type (Skylake, Cascade
  Lake, and Ice Lake were all observed), which introduces roughly 20% run-to-run variance in
  alignment time. Benchmark with multiple runs.

## References

- [Sentieon HealthOmics Guide](https://github.com/Sentieon/sentieon-amazon-omics)
- [Sentieon DNAscope Documentation](https://support.sentieon.com/manual/DNAscope_usage/)
