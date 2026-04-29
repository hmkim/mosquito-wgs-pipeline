# Sentieon DNAscope — Ae. aegypti WGS on AWS HealthOmics

Sentieon DNAscope germline variant calling pipeline for mosquito whole-genome sequencing,
running as an AWS HealthOmics private workflow with VPC-based license server.

## Architecture

- **License Server**: t3.medium EC2 in VPC, running `sentieon licsrvr` on port 8990
- **HealthOmics Workflow**: WDL pipeline using VPC networking (`--network-configuration`)
- **Pipeline**: Sentieon BWA → LocusCollector → Dedup → DNAscope (gVCF)

## Prerequisites

- AWS CLI v2 configured with `ap-northeast-2` region
- Docker (for image build)
- VPC ID, Subnet ID, VPC CIDR of the target VPC
- Sentieon license file (obtained from Don Freed at Sentieon)

## Setup Steps

### Step 1 — Deploy License Server

```bash
export VPC_ID=vpc-xxxxx
export SUBNET_ID=subnet-xxxxx
export VPC_CIDR=10.0.0.0/16

./deploy-sentieon.sh --license-stack
```

Note the **Private IP** in the output — send it to Don Freed to obtain a license file.

### Step 2 — Install License File

After receiving the `.lic` file from Sentieon:

```bash
# Upload to S3
aws s3 cp Sentieon_NEA-EHI.lic \
  s3://nea-ehi-wgs-data-<ACCOUNT_ID>-ap-northeast-2/sentieon/

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
./deploy-sentieon.sh --register
```

### Step 5 — Submit Test Run

```bash
./deploy-sentieon.sh --run
```

### Step 6 — Monitor

```bash
./deploy-sentieon.sh --status

# Or directly:
aws omics get-run --id <RUN_ID> --region ap-northeast-2
aws omics list-run-tasks --id <RUN_ID> --region ap-northeast-2
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
| `sentieon-dnascope-mosquito.wdl` | WDL workflow (BWA → Dedup → DNAscope) |
| `Dockerfile` | Container image (amazonlinux:2 + Sentieon 202503.03) |
| `deploy-sentieon.sh` | Deployment and management script |
| `run-inputs-SRR6063611.json` | Test run parameters |
| `omics-permissions-policy.json` | HealthOmics IAM permissions |
| `omics-ecr-policy.json` | ECR repository policy for HealthOmics |

## Expected Performance

| Pipeline | Platform | Time | Cost |
|----------|----------|------|------|
| GATK (BWA-mem2) | HealthOmics | 27.4h | ~$10.46 |
| Sentieon DNAscope | HealthOmics | ~2-3h (est.) | ~$6-9 (est.) |
| Parabricks GPU | AWS Batch g5.12xlarge | 37min | $3.66 |

## References

- [Sentieon HealthOmics Guide](https://github.com/Sentieon/sentieon-amazon-omics)
- [Sentieon DNAscope Documentation](https://support.sentieon.com/manual/DNAscope_usage/)
