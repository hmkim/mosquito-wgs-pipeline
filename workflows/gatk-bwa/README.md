# GATK Pipeline — BWA v0.7.19 Variant

This is an alternative version of the per-sample GATK pipeline that uses **BWA v0.7.19** (original `bwa mem`) instead of BWA-mem2.

## Test Result: BWA v0.7.19 Does NOT Improve HealthOmics Performance

BWA v0.7.19 was tested on HealthOmics (Run ID: 6503897) to validate whether removing SIMD dependency would eliminate the 5.4x alignment slowdown observed with BWA-mem2.

| Metric | BWA-mem2 (HealthOmics) | BWA v0.7.19 (HealthOmics) | EC2 BWA-mem2 |
|---|---:|---:|---:|
| Alignment time | 482 min | **456 min** | 90 min |
| vs EC2 | 5.4x slower | **5.1x slower** | baseline |

**Conclusion:** BWA-mem2 without AVX-512 regresses to BWA v0.7.x speed. Switching aligners does not help — the ~5x gap is a combination of lost SIMD acceleration (~3.3x) and general CPU performance difference (~1.5x). GPU acceleration (Parabricks) is the recommended workaround.

## Differences from BWA-mem2 version

| Component | `workflows/gatk/` (BWA-mem2) | `workflows/gatk-bwa/` (BWA) |
|---|---|---|
| Aligner | BWA-mem2 v2.2.1 | BWA v0.7.19 |
| Index files | `.0123`, `.bwt.2bit.64`, `.ann`, `.amb`, `.pac` | `.bwt`, `.ann`, `.amb`, `.pac`, `.sa` |
| Docker image | `nea-ehi-gatk:latest` | `nea-ehi-gatk-bwa:latest` |
| WDL | `gatk-mosquito.wdl` | `gatk-mosquito-bwa.wdl` |

## Pre-requisites

BWA v0.7.x requires its own index (different from BWA-mem2). Generate it on EC2:

```bash
cd /path/to/reference/mosquito/AaegL5
bwa index AaegL5.fasta
# Output: AaegL5.fasta.{bwt,ann,amb,pac,sa}

# Upload to S3
aws s3 cp AaegL5.fasta.bwt s3://<BUCKET>/reference/mosquito/AaegL5/
aws s3 cp AaegL5.fasta.sa  s3://<BUCKET>/reference/mosquito/AaegL5/
# (.ann, .amb, .pac are shared with BWA-mem2 and already in S3)
```

## Deploy to HealthOmics

```bash
# 1. Build and push Docker image
aws ecr create-repository --repository-name nea-ehi-gatk-bwa --region <REGION>
aws ecr get-login-password --region <REGION> | \
  docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com
docker build -t nea-ehi-gatk-bwa:latest .
docker tag nea-ehi-gatk-bwa:latest <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/nea-ehi-gatk-bwa:latest
docker push <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/nea-ehi-gatk-bwa:latest

# 2. Grant HealthOmics ECR access (same policy as before)
aws ecr set-repository-policy --repository-name nea-ehi-gatk-bwa \
  --policy-text file://../../workflows/gatk/omics-ecr-policy.json --region <REGION>

# 3. Register workflow
zip gatk-mosquito-bwa-workflow.zip gatk-mosquito-bwa.wdl
aws omics create-workflow --name gatk-mosquito-bwa --engine WDL \
  --definition-zip fileb://gatk-mosquito-bwa-workflow.zip \
  --main gatk-mosquito-bwa.wdl --region <REGION>

# 4. Start run
aws omics start-run \
  --workflow-id <WORKFLOW_ID> \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/nea-ehi-omics-workflow-role \
  --name "SRR6063611-bwa-run" \
  --output-uri s3://<BUCKET>/omics-output/ \
  --parameters file://run-inputs-SRR6063611.json \
  --storage-type DYNAMIC --log-level ALL --region <REGION>
```
