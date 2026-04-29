# Execution Plan — Parabricks GPU on HealthOmics

**Date:** 2026-04-23
**Objective:** Execute Parabricks `fq2bam` + `haplotypecaller` on AWS HealthOmics GPU instances in ap-northeast-2.
**Sample:** SRR6063611 (*Ae. aegypti*, 98M read pairs, ~23x coverage)

---

## Infrastructure State (updated 2026-04-27)

| Resource | Status | Details |
|---|---|---|
| S3 Bucket | ✅ Ready | `nea-ehi-wgs-data-664263524008-ap-northeast-2` |
| FASTQ files | ✅ Ready | `s3://.../raw/mosquito-wgs/SRR6063611/SRR6063611_R{1,2}.fastq.gz` (~10 GB each) |
| Reference files | ✅ Ready | All individual files present (FASTA, FAI, DICT, BWA indices) |
| Reference tarball | ✅ Built | `AaegL5.fasta.tar` (3.3 GiB) in S3 |
| Parabricks ECR repo | ✅ Created | `parabricks:4.3.1-1` in ap-northeast-2, us-east-1, ap-southeast-1 |
| IAM Role | ✅ Updated | `nea-ehi-omics-workflow-role` includes `parabricks` ECR access |
| HealthOmics Workflows | ✅ Registered | v4 (1418762), v5 (2351613), v6 (6693313), v6b (5652212) |
| EC2 Instance | ✅ Available | `i-0b0068e92b2060948` (r5.4xlarge) |

**Outcome:** HealthOmics GPU runs failed (T4 CUDA OOM at HC stage, A10G unavailable in ap-northeast-2). Pipeline succeeded via **AWS Batch g5.12xlarge** — see `batch-execution-plan.md` and `batch-run.sh`.

---

## Execution Steps

### Step 1: Build Reference Tarball (EC2)

Parabricks HealthOmics workflows require the reference as a single flat `.tar` file.

**On EC2 instance:**

```bash
# Connect to EC2
aws ssm start-session --target i-0b0068e92b2060948 --region ap-northeast-2

# Download reference files from S3
cd /home/ec2-user/wgs-pipeline/reference/mosquito/AaegL5

# Verify all required files exist
ls -lh AaegL5.fasta AaegL5.fasta.fai AaegL5.dict \
       AaegL5.fasta.bwt AaegL5.fasta.ann AaegL5.fasta.amb \
       AaegL5.fasta.pac AaegL5.fasta.sa

# If .bwt or .sa missing (uploaded today for BWA run), download from S3
aws s3 cp s3://nea-ehi-wgs-data-664263524008-ap-northeast-2/reference/mosquito/AaegL5/AaegL5.fasta.bwt .
aws s3 cp s3://nea-ehi-wgs-data-664263524008-ap-northeast-2/reference/mosquito/AaegL5/AaegL5.fasta.sa .

# Create flat tarball (no directory prefix)
tar cf AaegL5.fasta.tar \
    AaegL5.fasta \
    AaegL5.fasta.fai \
    AaegL5.dict \
    AaegL5.fasta.bwt \
    AaegL5.fasta.ann \
    AaegL5.fasta.amb \
    AaegL5.fasta.pac \
    AaegL5.fasta.sa

# Verify: flat structure, no directory prefix
tar tf AaegL5.fasta.tar

# Check size (expected ~5-6 GB)
ls -lh AaegL5.fasta.tar

# Upload to S3
aws s3 cp AaegL5.fasta.tar \
    s3://nea-ehi-wgs-data-664263524008-ap-northeast-2/reference/mosquito/AaegL5/AaegL5.fasta.tar
```

**Expected time:** ~10-15 min (tar + S3 upload)

---

### Step 2: Push Parabricks Container to ECR

HealthOmics requires containers in private ECR. Must use the Amazon Linux variant.

**On EC2 instance (or local machine with Docker):**

```bash
# Create ECR repository
aws ecr create-repository --repository-name parabricks --region ap-northeast-2

# Grant HealthOmics access to ECR repository
aws ecr set-repository-policy --repository-name parabricks --region ap-northeast-2 \
    --policy-text '{
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "omics",
            "Effect": "Allow",
            "Principal": {"Service": "omics.amazonaws.com"},
            "Action": [
                "ecr:GetDownloadUrlForLayer",
                "ecr:BatchGetImage",
                "ecr:BatchCheckLayerAvailability"
            ],
            "Condition": {
                "StringEquals": {"aws:SourceAccount": "664263524008"}
            }
        }]
    }'

# Login to NGC (requires free NGC account at https://ngc.nvidia.com)
docker login nvcr.io
# Username: $oauthtoken
# Password: <NGC_API_KEY>

# Pull Amazon Linux variant (REQUIRED for HealthOmics)
docker pull nvcr.io/nvidia/clara/nvidia_clara_parabricks_amazon_linux:4.3.1-1

# Login to ECR
aws ecr get-login-password --region ap-northeast-2 | \
    docker login --username AWS --password-stdin 664263524008.dkr.ecr.ap-northeast-2.amazonaws.com

# Tag and push
docker tag nvcr.io/nvidia/clara/nvidia_clara_parabricks_amazon_linux:4.3.1-1 \
    664263524008.dkr.ecr.ap-northeast-2.amazonaws.com/parabricks:4.3.1-1
docker push 664263524008.dkr.ecr.ap-northeast-2.amazonaws.com/parabricks:4.3.1-1
```

**Expected time:** ~15-30 min (pull ~15 GB image, push to ECR)

**Note:** EC2 r5.4xlarge has no GPU and limited disk. If Docker image pull fails due to disk space, use a machine with Docker installed and sufficient storage (~30 GB free).

**Fallback:** If v4.3.1-1 is unavailable or `--low-memory` fails, use v4.1.1-1 (validated by NVIDIA's official HealthOmics workflows):
```bash
docker pull nvcr.io/nvidia/clara/nvidia_clara_parabricks_amazon_linux:4.1.1-1
```

---

### Step 3: Update IAM Role

The existing IAM role only allows ECR pull from `nea-ehi-gatk`. Add the new `parabricks` repository.

```bash
# Get current policy
aws iam get-role-policy \
    --role-name nea-ehi-omics-workflow-role \
    --policy-name omics-workflow-permissions

# Update policy to add parabricks ECR access
aws iam put-role-policy \
    --role-name nea-ehi-omics-workflow-role \
    --policy-name omics-workflow-permissions \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "S3ReadWrite",
                "Effect": "Allow",
                "Action": [
                    "s3:GetObject",
                    "s3:PutObject",
                    "s3:GetBucketLocation",
                    "s3:ListBucket"
                ],
                "Resource": [
                    "arn:aws:s3:::nea-ehi-wgs-data-664263524008-ap-northeast-2",
                    "arn:aws:s3:::nea-ehi-wgs-data-664263524008-ap-northeast-2/*"
                ]
            },
            {
                "Sid": "ECRAuth",
                "Effect": "Allow",
                "Action": "ecr:GetAuthorizationToken",
                "Resource": "*"
            },
            {
                "Sid": "ECRPull",
                "Effect": "Allow",
                "Action": [
                    "ecr:BatchGetImage",
                    "ecr:GetDownloadUrlForLayer",
                    "ecr:BatchCheckLayerAvailability"
                ],
                "Resource": [
                    "arn:aws:ecr:ap-northeast-2:664263524008:repository/nea-ehi-gatk",
                    "arn:aws:ecr:ap-northeast-2:664263524008:repository/parabricks"
                ]
            },
            {
                "Sid": "CloudWatchLogs",
                "Effect": "Allow",
                "Action": [
                    "logs:CreateLogGroup",
                    "logs:CreateLogStream",
                    "logs:PutLogEvents"
                ],
                "Resource": "arn:aws:logs:ap-northeast-2:664263524008:log-group:/aws/omics/*"
            }
        ]
    }'
```

**Expected time:** Instant

---

### Step 4: Register HealthOmics Workflow

```bash
cd /home/ec2-user/project-NEA-EHI/workflows/parabricks

# Create workflow zip
zip germline-haplotype-workflow.zip germline-haplotype.wdl

# Register with HealthOmics
aws omics create-workflow \
    --name parabricks-germline \
    --engine WDL \
    --definition-zip fileb://germline-haplotype-workflow.zip \
    --main germline-haplotype.wdl \
    --region ap-northeast-2

# Record the workflow ID: __________
```

**Expected time:** ~2-5 min (workflow validation)

---

### Step 5: Update run-inputs JSON

Update `run-inputs-SRR6063611.json` with actual values:

```json
{
  "ParabricksGermline.inputFASTQ_1": "s3://nea-ehi-wgs-data-664263524008-ap-northeast-2/raw/mosquito-wgs/SRR6063611/SRR6063611_R1.fastq.gz",
  "ParabricksGermline.inputFASTQ_2": "s3://nea-ehi-wgs-data-664263524008-ap-northeast-2/raw/mosquito-wgs/SRR6063611/SRR6063611_R2.fastq.gz",
  "ParabricksGermline.inputRefTarball": "s3://nea-ehi-wgs-data-664263524008-ap-northeast-2/reference/mosquito/AaegL5/AaegL5.fasta.tar",
  "ParabricksGermline.sample_id": "SRR6063611",
  "ParabricksGermline.pb_version": "4.3.1-1",
  "ParabricksGermline.ecr_registry": "664263524008.dkr.ecr.ap-northeast-2.amazonaws.com"
}
```

---

### Step 6: Start HealthOmics Run

```bash
aws omics start-run \
    --workflow-id <WORKFLOW_ID> \
    --role-arn arn:aws:iam::664263524008:role/nea-ehi-omics-workflow-role \
    --name "SRR6063611-parabricks-v1" \
    --output-uri s3://nea-ehi-wgs-data-664263524008-ap-northeast-2/omics-output/ \
    --parameters file://run-inputs-SRR6063611.json \
    --storage-type DYNAMIC \
    --log-level ALL \
    --region ap-northeast-2

# Record the run ID: __________
```

---

### Step 7: Monitor & Validate

```bash
# Run status
aws omics get-run --id <RUN_ID> --region ap-northeast-2 \
    --query '{status:status,startTime:startTime,stopTime:stopTime}'

# Task statuses (with GPU info)
aws omics list-run-tasks --id <RUN_ID> --region ap-northeast-2 \
    --query 'items[].{name:name,status:status,cpus:cpus,memory:memory,gpus:gpus,startTime:startTime,stopTime:stopTime}'
```

---

## Dependency Graph

```
Step 1 (tarball)  ──┐
                    ├──► Step 4 (register WDL) ──► Step 5 (JSON) ──► Step 6 (start run)
Step 2 (ECR push) ──┤
                    │
Step 3 (IAM)  ──────┘
```

Steps 1, 2, 3 are **independent** and can run in parallel.

---

## Risk & Mitigation

| Risk | Impact | Mitigation |
|---|---|---|
| `--low-memory` not in v4.3.1-1 | Run fails at fq2bam | Re-push v4.1.1-1 container, re-run |
| EC2 disk space for Docker pull (~15 GB) | Cannot pull image | Use local machine or resize EBS volume |
| NGC account required | Cannot pull Parabricks image | Create free account at ngc.nvidia.com |
| A10G not available in ap-northeast-2 | Falls back to T4 (16 GiB) | `--low-memory` flag handles T4; `nvidia-tesla-t4-a10g` allows both |
| Reference tarball not flat | Parabricks can't find ref files | Verify with `tar tf` before upload |
| IAM role missing ECR permission | Container pull fails | Step 3 adds `parabricks` repo to policy |

---

## Expected Timeline

| Step | Duration | Can Parallelize |
|---|---|---|
| Step 1: Reference tarball | ~10-15 min | Yes |
| Step 2: ECR push | ~15-30 min | Yes (longest step) |
| Step 3: IAM update | ~1 min | Yes |
| Step 4: Register workflow | ~2-5 min | After Steps 1-3 |
| Step 5: Update JSON | ~1 min | After Step 4 |
| Step 6: Start run | ~1 min | After Step 5 |
| **Total prep time** | **~20-35 min** | Steps 1-3 in parallel |
| **Run time (estimated)** | **1-3 hours** | — |

---

## Success Criteria

| Criterion | Target | Rationale |
|---|---|---|
| fq2bam completes | < 60 min | Significant speedup over CPU (482 min BWA-mem2) |
| HaplotypeCaller completes | < 120 min | Significant speedup over CPU (1,080 min) |
| Total pipeline time | < 3 hours | At least 9x faster than CPU HealthOmics (27.4h) |
| gVCF output valid | `bcftools view -h` shows `<NON_REF>` | Standard gVCF format |
| Mapping rate | > 90% | Comparable to CPU baseline |

---

## Post-Run Validation

```bash
# 1. Download output
aws s3 cp s3://nea-ehi-wgs-data-664263524008-ap-northeast-2/omics-output/<RUN_ID>/out/ \
    ./pb_output/ --recursive

# 2. gVCF verification
bcftools stats ./pb_output/SRR6063611.g.vcf.gz | grep "^SN"

# 3. Concordance with CPU gVCF (from BWA-mem2 or BWA run)
bcftools view -v snps -r NC_035107.1:1-1000000 ./pb_output/SRR6063611.g.vcf.gz | \
    bcftools stats - | grep "number of SNPs"

# 4. If BAM available, check alignment stats
samtools flagstat ./pb_output/SRR6063611.pb.bam
```
