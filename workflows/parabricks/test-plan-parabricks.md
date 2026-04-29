# Test Plan — Parabricks GPU-Accelerated Pipeline on AWS HealthOmics

**Date:** 2026-04-23
**Objective:** Test NVIDIA Parabricks `fq2bam` + `haplotypecaller` on AWS HealthOmics using GPU instances (4x T4) and compare performance/cost against CPU baselines.
**Sample:** SRR6063611 (*Ae. aegypti*, 98M read pairs, NextSeq 500, ~23x coverage)
**Reference:** AaegL5 (GCF_002204515.2, 1.279 Gb)

---

## 1. HealthOmics GPU Instance Support

AWS HealthOmics supports GPU instances via WDL `runtime` attributes:

```wdl
runtime {
    acceleratorType: "nvidia-tesla-t4-a10g"   # T4 or A10G, auto-selected
    acceleratorCount: 4
    cpu: 48
    memory: "192 GiB"
}
```

### Available GPU Instances (ap-northeast-2)

| acceleratorType | GPU | Instance Family | VRAM/GPU | 4-GPU Instance |
|---|---|---|---|---|
| `nvidia-tesla-t4` | T4 | G4dn | 16 GiB | omics.g4dn.12xlarge (48 vCPU, 192 GiB) |
| `nvidia-tesla-t4-a10g` | T4 or A10G | G4dn, G5 | 16-24 GiB | omics.g4dn.12xlarge or omics.g5.12xlarge |
| `nvidia-tesla-a10g` | A10G | G5 | 24 GiB | omics.g5.12xlarge (48 vCPU, 192 GiB) |

Additional types (us-west-2/us-east-1 only): `nvidia-l4` (G6, 24 GiB), `nvidia-l40s` (G6e, 48 GiB).

Our WDL uses **`nvidia-tesla-t4-a10g`** — HealthOmics auto-selects between G4dn and G5 based on availability, preferring lower cost. If G5 (A10G, 24 GiB VRAM) is assigned, `--low-memory` flag becomes unnecessary but remains harmless.

### Source

- AWS HealthOmics [compute and memory](https://docs.aws.amazon.com/omics/latest/dev/memory-and-compute-tasks.html)
- AWS HealthOmics [task accelerators](https://docs.aws.amazon.com/omics/latest/dev/task-accelerators.html)
- NVIDIA's official HealthOmics workflows: [parabricks-omics-private-workflows](https://github.com/clara-parabricks-workflows/parabricks-omics-private-workflows)

---

## 2. Architecture

```
                       AWS HealthOmics Private Workflow
                       ┌──────────────────────────────────┐
  S3 FASTQ             │  Task: fq2bam                    │
  ─────────────────►   │  4x T4/A10G GPU, 48 vCPU, 192GB │
                       │  Parabricks fq2bam               │
  S3 Reference.tar     │  (align + sort + markdup)        │
  ─────────────────►   │  --low-memory                    │
                       └────────────┬─────────────────────┘
                                    │ BAM
                       ┌────────────▼─────────────────────┐
                       │  Task: haplotypecaller            │
                       │  4x T4/A10G GPU, 48 vCPU, 192GB  │
                       │  Parabricks haplotypecaller       │
                       │  --gvcf                           │
                       └────────────┬─────────────────────┘
                                    │ gVCF
                                    ▼
                              S3 Output
```

### Differences from CPU GATK Workflow

| Aspect | CPU GATK (workflows/gatk/) | Parabricks GPU |
|---|---|---|
| Steps | 6 (FastQC → FastP → BWA → Sort → MarkDup → HC) | 2 (fq2bam → HC) |
| Trimming | FastP (Q20, min 50bp) | None (BWA-MEM soft-clips) |
| Aligner | BWA-mem2 / BWA | GPU BWA-MEM |
| Reference format | Individual files (FASTA + indices) | Single `.tar` tarball |
| Instance type | omics.m.2xlarge (CPU) | omics.g4dn.12xlarge or omics.g5.12xlarge |
| Container | Custom GATK + tools | Parabricks Amazon Linux |
| `--low-memory` | N/A | Required for T4 (16 GiB), optional for A10G (24 GiB) |

---

## 3. Pre-requisites

### 3.1 Build Reference Tarball

Parabricks HealthOmics workflows expect the reference genome as a single `.tar` file containing the FASTA, FAI, DICT, and BWA index files.

```bash
# On EC2 instance
cd /home/ec2-user/wgs-pipeline/reference/mosquito/AaegL5

# Generate BWA v0.7.x index if not already present
# (Parabricks uses standard BWA index, not BWA-mem2)
bwa index AaegL5.fasta

# Verify all required files exist
ls -lh AaegL5.fasta AaegL5.fasta.fai AaegL5.dict \
       AaegL5.fasta.bwt AaegL5.fasta.ann AaegL5.fasta.amb \
       AaegL5.fasta.pac AaegL5.fasta.sa

# Create tarball (NOTE: tar must be flat — no directory prefix)
tar cf AaegL5.fasta.tar \
    AaegL5.fasta \
    AaegL5.fasta.fai \
    AaegL5.dict \
    AaegL5.fasta.bwt \
    AaegL5.fasta.ann \
    AaegL5.fasta.amb \
    AaegL5.fasta.pac \
    AaegL5.fasta.sa

# Verify tarball contents
tar tf AaegL5.fasta.tar
# Expected (no path prefix, just filenames):
#   AaegL5.fasta
#   AaegL5.fasta.fai
#   AaegL5.dict
#   AaegL5.fasta.bwt
#   AaegL5.fasta.ann
#   AaegL5.fasta.amb
#   AaegL5.fasta.pac
#   AaegL5.fasta.sa

ls -lh AaegL5.fasta.tar
# Expected: ~5-6 GB

# Upload to S3
aws s3 cp AaegL5.fasta.tar s3://<BUCKET>/reference/mosquito/AaegL5/AaegL5.fasta.tar
```

### 3.2 Push Parabricks Container to ECR

HealthOmics requires containers in private ECR. The public NGC image cannot be used directly.

```bash
# Create ECR repository
aws ecr create-repository --repository-name parabricks --region <REGION>

# Login to NGC (requires free NGC account at https://ngc.nvidia.com)
docker login nvcr.io
# Username: $oauthtoken
# Password: <NGC_API_KEY>

# Pull the Amazon Linux variant (required for HealthOmics)
docker pull nvcr.io/nvidia/clara/nvidia_clara_parabricks_amazon_linux:4.3.1-1

# Login to ECR
aws ecr get-login-password --region <REGION> | \
    docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com

# Tag and push
docker tag nvcr.io/nvidia/clara/nvidia_clara_parabricks_amazon_linux:4.3.1-1 \
    <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/parabricks:4.3.1-1
docker push <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/parabricks:4.3.1-1

# Grant HealthOmics access to ECR
aws ecr set-repository-policy --repository-name parabricks \
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
                "StringEquals": {"aws:SourceAccount": "<ACCOUNT_ID>"}
            }
        }]
    }' --region <REGION>
```

**Important:** Use the `nvidia_clara_parabricks_amazon_linux` image variant, not the standard `clara-parabricks`. The Amazon Linux variant is designed for AWS environments.

### 3.3 Register HealthOmics Workflow

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
    --region <REGION>

# Record the workflow ID: __________
```

### 3.4 Update IAM Role

The existing `nea-ehi-omics-workflow-role` should work if it already has S3 and ECR permissions. Verify it can access the new `parabricks` ECR repository.

### 3.5 Update run-inputs JSON

Edit `run-inputs-SRR6063611.json` with actual values:

```json
{
  "ParabricksGermline.inputFASTQ_1": "s3://<BUCKET>/raw/mosquito-wgs/SRR6063611/SRR6063611_R1.fastq.gz",
  "ParabricksGermline.inputFASTQ_2": "s3://<BUCKET>/raw/mosquito-wgs/SRR6063611/SRR6063611_R2.fastq.gz",
  "ParabricksGermline.inputRefTarball": "s3://<BUCKET>/reference/mosquito/AaegL5/AaegL5.fasta.tar",
  "ParabricksGermline.sample_id": "SRR6063611",
  "ParabricksGermline.pb_version": "4.3.1-1",
  "ParabricksGermline.ecr_registry": "<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com"
}
```

---

## 4. Execution

### 4.1 Start HealthOmics Run

```bash
aws omics start-run \
    --workflow-id <WORKFLOW_ID> \
    --role-arn arn:aws:iam::<ACCOUNT_ID>:role/nea-ehi-omics-workflow-role \
    --name "SRR6063611-parabricks-v1" \
    --output-uri s3://<BUCKET>/omics-output/ \
    --parameters file://run-inputs-SRR6063611.json \
    --storage-type DYNAMIC \
    --log-level ALL \
    --region <REGION>

# Record the run ID: __________
```

### 4.2 Monitor Progress

```bash
# Run status
aws omics get-run --id <RUN_ID> --region <REGION> \
    --query '{status:status,startTime:startTime,stopTime:stopTime}'

# Task statuses
aws omics list-run-tasks --id <RUN_ID> --region <REGION> \
    --query 'items[].{name:name,status:status,cpus:cpus,memory:memory,gpus:gpus,startTime:startTime,stopTime:stopTime}'
```

---

## 5. Validation

### 5.1 Performance Comparison (4-way, actual results)

| Task | EC2 CPU (m5.2xlarge) | HealthOmics CPU (BWA-mem2) | HealthOmics GPU (T4) | **Batch GPU (A10G)** |
|---|---|---|---|---|
| FastQC | ~15 min | 18 min | N/A | N/A |
| FastP | ~15 min | 12 min | N/A | N/A |
| Align+Sort+MarkDup | ~135 min | 532 min | ~38 min (fq2bam OK) | **14 min** |
| HaplotypeCaller | ~588 min | 1,080 min | **CUDA OOM** | **23 min** |
| **Total** | **~753 min (12.6h)** | **~1,642 min (27.4h)** | **FAILED** | **37 min** |

### 5.2 Cost Comparison (actual results)

| Approach | Platform | Runtime | Cost |
|---|---|---|---|
| CPU BWA-mem2 | EC2 m5.2xlarge | 12.6h | ~$7.02 |
| CPU BWA-mem2 | HealthOmics | 27.4h | ~$10.46 |
| GPU Parabricks | HealthOmics (T4 — OOM) | FAILED | — |
| **GPU Parabricks** | **Batch g5.12xlarge (A10G)** | **37 min** | **~$3.66** |

HealthOmics GPU with T4 is insufficient for HaplotypeCaller on this genome. A10G via `nvidia-tesla-a10g` only available in us-east-1.

### 5.3 gVCF Concordance

```bash
# Download Parabricks gVCF output
aws s3 cp s3://<BUCKET>/omics-output/<RUN_ID>/out/ ./pb_output/ --recursive

# Compare against CPU GATK gVCF (from previous HealthOmics run)
echo "=== CPU GATK gVCF ==="
bcftools view -v snps <cpu_gvcf> -r NC_035107.1:1-1000000 | bcftools stats - | grep "number of SNPs"

echo "=== Parabricks gVCF ==="
bcftools view -v snps ./pb_output/SRR6063611.g.vcf.gz -r NC_035107.1:1-1000000 | bcftools stats - | grep "number of SNPs"

# Full concordance check
bcftools isec <cpu_gvcf_snps> <pb_gvcf_snps> -p ./concordance/
echo "CPU-only: $(grep -c '^[^#]' ./concordance/0000.vcf)"
echo "PB-only:  $(grep -c '^[^#]' ./concordance/0001.vcf)"
echo "Shared:   $(grep -c '^[^#]' ./concordance/0002.vcf)"
```

### 5.4 Alignment Statistics

```bash
# From Parabricks BAM output
samtools flagstat ./pb_output/SRR6063611.pb.bam
# Mapping rate should be >90%, similar to CPU baseline
```

---

## 6. Success Criteria

| Criterion | Target | Rationale |
|---|---|---|
| fq2bam time | < 60 min | Significant improvement over CPU (482 min on HealthOmics) |
| HaplotypeCaller time | < 120 min | Significant improvement over CPU (1,080 min on HealthOmics) |
| Total pipeline time | < 3 hours | At least 9x faster than CPU HealthOmics |
| Per-sample cost | < $10 | Competitive with or cheaper than CPU HealthOmics ($10.46) |
| gVCF concordance | > 99% SNP overlap | Functionally equivalent output |
| Mapping rate | > 90% | Comparable to CPU baseline |

---

## 7. Potential Issues and Mitigations

### 7.1 Reference Tarball Extraction

The tarball must be flat (no directory prefix). If `tar xf` creates a subdirectory, Parabricks won't find the files. Verify with `tar tf` before uploading.

### 7.2 GPU Memory (T4: 16 GiB, A10G: 24 GiB VRAM)

With `nvidia-tesla-t4-a10g`, HealthOmics may assign T4 (16 GiB) or A10G (24 GiB). The `--low-memory` flag in fq2bam is **required** for T4 (default needs ~38 GB) but harmless on A10G. This flag is already included in our WDL. HaplotypeCaller does not need this flag.

### 7.3 Parabricks Container Variant

Must use `nvidia_clara_parabricks_amazon_linux` (not standard `clara-parabricks`). The Amazon Linux variant is required for HealthOmics compute environment compatibility.

### 7.4 WDL Version Compatibility

HealthOmics uses WDL 1.0. Our WDL is written in 1.0 format with HealthOmics-native `runtime` blocks (acceleratorType/acceleratorCount). The newer WDL 1.2 workflows from `Parabricks-WDL-Workflows` use `requirements`/`hints` blocks which may not be directly compatible.

### 7.5 gVCF Output Format

Parabricks haplotypecaller with `--gvcf` may output uncompressed `.g.vcf` rather than `.g.vcf.gz`. Check output and compress/index if needed:

```bash
bgzip SRR6063611.g.vcf && tabix -p vcf SRR6063611.g.vcf.gz
```

Our WDL requests `.g.vcf.gz` output directly — verify Parabricks honors this.

---

## 8. Decision Matrix (post-test) — RESOLVED

**Outcome: HC fails on HealthOmics T4 (CUDA OOM); Batch g5 A10G validated.**

| Result | Recommendation | Status |
|---|---|---|
| ~~Total < 1h, cost < $8~~ | ~~Adopt Parabricks on HealthOmics~~ | N/A — HC fails on T4 |
| Run fails (GPU OOM) | Switch to A10G | **Actual outcome** — A10G unavailable on HealthOmics (ap-northeast-2) |
| **Final recommendation** | **Use AWS Batch g5.12xlarge (4x A10G)** | **37 min, $3.66/sample** |

---

## 9. Next Steps After Successful Test

### 9.1 Batch Processing (5 samples)

Update `run-inputs` for each sample and submit 5 runs:

```bash
for SID in SRR6063610 SRR6063611 SRR6063612 SRR6063613 SRR6118663; do
    cat > run-inputs-${SID}.json << EOFJ
{
  "ParabricksGermline.inputFASTQ_1": "s3://<BUCKET>/raw/mosquito-wgs/${SID}/${SID}_R1.fastq.gz",
  "ParabricksGermline.inputFASTQ_2": "s3://<BUCKET>/raw/mosquito-wgs/${SID}/${SID}_R2.fastq.gz",
  "ParabricksGermline.inputRefTarball": "s3://<BUCKET>/reference/mosquito/AaegL5/AaegL5.fasta.tar",
  "ParabricksGermline.sample_id": "${SID}",
  "ParabricksGermline.pb_version": "4.3.1-1",
  "ParabricksGermline.ecr_registry": "<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com"
}
EOFJ

    aws omics start-run \
        --workflow-id <WORKFLOW_ID> \
        --role-arn arn:aws:iam::<ACCOUNT_ID>:role/nea-ehi-omics-workflow-role \
        --name "${SID}-parabricks" \
        --output-uri s3://<BUCKET>/omics-output/ \
        --parameters file://run-inputs-${SID}.json \
        --storage-type DYNAMIC --log-level ALL --region <REGION>
done
```

### 9.2 Joint Genotyping

Parabricks gVCFs are GATK-compatible. Feed into existing joint genotyping pipeline:

```bash
# Use existing workflows/gatk/joint-genotyping.wdl or scripts/04_joint_genotyping.sh
# Input: 5 per-sample gVCFs from Parabricks
# Output: Filtered cohort VCF
```

### 9.3 Update Documentation

After results are collected:
- Update `test-results.md` with Parabricks timing and cost
- Update `healthomics-performance-report.md` with 3-way comparison
- Update `README.md` Pipeline Variants table

---

## References

- [parabricks-omics-private-workflows](https://github.com/clara-parabricks-workflows/parabricks-omics-private-workflows) — NVIDIA's official HealthOmics GPU workflows
- [Parabricks-WDL-Workflows](https://github.com/clara-parabricks-workflows/Parabricks-WDL-Workflows) — Latest WDL 1.2 task/workflow definitions
- [AWS HealthOmics GPU support](https://docs.aws.amazon.com/omics/latest/dev/workflow-resources.html) — acceleratorType, acceleratorCount
- [Parabricks system requirements](https://docs.nvidia.com/clara/parabricks/4.3.1/gettingstarted.html) — GPU VRAM, --low-memory flag
- [NGC container registry](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/clara/containers/nvidia_clara_parabricks_amazon_linux) — Amazon Linux variant for AWS
