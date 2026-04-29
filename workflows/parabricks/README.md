# Parabricks GPU-Accelerated Pipeline

NVIDIA Parabricks provides GPU-accelerated implementations of BWA-MEM alignment, sorting, duplicate marking, and GATK HaplotypeCaller. The entire per-sample pipeline reduces to two steps: `fq2bam` + `haplotypecaller`.

## Test Result (2026-04-26)

Parabricks on AWS Batch g5.12xlarge (4x A10G) completed the full per-sample pipeline in **37 minutes** — 20x faster and 48% cheaper than EC2 CPU baseline.

| Step | Duration | Equivalent CPU tasks |
|---|---:|---|
| **fq2bam** (align + sort + markdup) | **14 min** | BWA-mem2 (90 min) + Sort (15 min) + MarkDup (30 min) = 135 min on EC2 |
| **HaplotypeCaller** (gVCF) | **23 min** | 588 min on EC2 |
| **Pipeline total** | **37 min** | **753 min (12.6h) on EC2** |

| Platform | Pipeline Time | Cost/Sample |
|---|---:|---:|
| EC2 m5.2xlarge (BWA-mem2, CPU) | 12.6h | $7.02 |
| HealthOmics (BWA-mem2, CPU) | 27.4h | $10.46 |
| **AWS Batch g5.12xlarge (Parabricks, GPU)** | **37 min** | **$3.66 (OD) / ~$1.40 (Spot)** |

### Variant Concordance vs CPU GATK HC

| Metric | Value |
|---|---|
| SNP Recall (vs EC2 CPU) | 95.8% |
| Genotype match (shared sites) | 100% |
| SNP Precision | 29.8% (9.6M extra calls from no trimming) |
| Ti/Tv | 0.43 (vs 1.20 for CPU — confirms FP excess) |

Low Precision is due to Parabricks running on raw FASTQ (no FastP trimming), not algorithm error. On shared sites, genotype concordance is 100%. Adding trimming or post-call filtering resolves FP excess.

## Deployment: AWS Batch (Validated)

### Infrastructure

| Component | Detail |
|---|---|
| Compute Environment | `nea-ehi-gpu-parabricks`, MANAGED, g5.12xlarge On-Demand |
| Job Queue | `nea-ehi-gpu-queue` |
| Job Definition | `parabricks-germline:2` (48 vCPU, 180 GB, 4 GPU) |
| ECR Image | `664263524008.dkr.ecr.ap-northeast-2.amazonaws.com/parabricks:4.3.1-1` |
| Storage | Local NVMe `/local_disk` (900 GB) |

### Running a Job

```bash
aws batch submit-job \
  --job-name parabricks-germline-SRR6063611 \
  --job-queue nea-ehi-gpu-queue \
  --job-definition parabricks-germline:2
```

The job script (`batch-run.sh`) downloads data from S3, runs fq2bam + haplotypecaller, and uploads results:

```bash
# fq2bam: FASTQ → sorted, deduped BAM
pbrun fq2bam \
  --ref AaegL5.fasta \
  --in-fq SRR6063611_R1.fastq.gz SRR6063611_R2.fastq.gz \
  "@RG\tID:SRR6063611\tLB:lib1\tPL:ILLUMINA\tSM:SRR6063611\tPU:unit1" \
  --out-bam SRR6063611.pb.bam \
  --tmp-dir /local_disk/tmp_fq2bam \
  --low-memory

# haplotypecaller: BAM → gVCF
pbrun haplotypecaller \
  --ref AaegL5.fasta \
  --in-bam SRR6063611.pb.bam \
  --out-variants SRR6063611.g.vcf \
  --gvcf
```

### Files

| File | Description |
|---|---|
| `batch-run.sh` | AWS Batch job script |
| `batch-execution-plan.md` | Batch infrastructure and execution plan |
| `run-parabricks.sh` | Standalone EC2 GPU script (Docker + nvidia-container-toolkit) |

## GPU Requirements

| Requirement | Detail |
|---|---|
| **GPU** | A10G (24 GiB VRAM) or better — **T4 (16 GiB) fails on HaplotypeCaller** |
| **Instance** | g5.12xlarge (4x A10G, 48 vCPU, 192 GiB) recommended |
| **Parabricks** | v4.3.1-1 |
| **CUDA** | Included in container |

The `--low-memory` flag in `fq2bam` reduces GPU memory usage. It is harmless on A10G and required for any T4-based runs (fq2bam-only use cases).

### Failed Attempts Log

| Run | Instance | Error | Root Cause |
|---|---|---|---|
| v1 | g4dn.12xlarge | Exit 127 | Wrong container; `pbrun` not found |
| v2 | g4dn.12xlarge | Exit 1, `No space left` | Disk mount issue |
| v3 | g4dn.12xlarge | Exit 255, HC error | T4 (16 GiB VRAM) insufficient for HC |
| **v4** | **g5.12xlarge** | **Exit 0** | **A10G (24 GiB VRAM) works** |

HealthOmics GPU runs failed due to T4 CUDA OOM at HC stage; A10G unavailable in ap-northeast-2. AWS Batch with g5.12xlarge (A10G) is the validated GPU path.

## HealthOmics GPU (Not Viable in ap-northeast-2)

HealthOmics supports GPU instances via WDL `runtime` attributes. However, Parabricks HaplotypeCaller requires A10G (24 GiB VRAM) — T4 (16 GiB) fails with CUDA OOM within seconds. In ap-northeast-2, `nvidia-tesla-a10g` returns `UNSUPPORTED_GPU_INSTANCE_TYPE`, and `nvidia-tesla-t4-a10g` always selects T4 (lowest cost), making HealthOmics GPU unusable for the full germline pipeline in this region.

**Root cause confirmed:** CUDA out-of-memory on T4 for *Ae. aegypti* 1.3 Gbp genome (verified via AWS Batch explicit error: `cudaSafeCall() failed: out of memory`).

**GPU Probe Regional Test Results (2026-04-27):**

| Region | acceleratorType | Result | Instance Assigned |
|---|---|---|---|
| us-east-1 | `nvidia-tesla-t4-a10g` | OK | omics.g4dn.12xlarge (T4) |
| us-east-1 | `nvidia-tesla-a10g` | OK | omics.g5.12xlarge (A10G) |
| ap-northeast-2 | `nvidia-tesla-t4-a10g` | OK | omics.g4dn.12xlarge (T4) |
| ap-northeast-2 | `nvidia-tesla-a10g` | **FAILED** | UNSUPPORTED_GPU_INSTANCE_TYPE |
| ap-southeast-1 | `nvidia-tesla-t4-a10g` | OK | omics.g4dn.12xlarge (T4) |
| ap-southeast-1 | `nvidia-tesla-a10g` | **FAILED** | UNSUPPORTED_GPU_INSTANCE_TYPE |

**Conclusion:** A10G is only available via HealthOmics in us-east-1. For ap-northeast-2 and ap-southeast-1, AWS Batch with g5.12xlarge is the only viable GPU path. Inquiry sent to HealthOmics SA team (see `healthomics-gpu-inquiry.eml`).

## Architecture

```
  S3 FASTQ ───► fq2bam (GPU)           ───► haplotypecaller (GPU) ───► S3 gVCF
                 align + sort + markdup        gVCF variant calling
                 4x A10G GPU                   4x A10G GPU
```

Parabricks replaces the per-sample alignment-to-variant-calling steps (6 CPU tasks → 2 GPU tasks). Joint genotyping (GenomicsDBImport + GenotypeGVCFs) remains CPU-based.

## Reference Tarball Format

Parabricks expects the reference as a single flat `.tar`:

```
AaegL5.fasta.tar
  ├── AaegL5.fasta      (reference FASTA)
  ├── AaegL5.fasta.fai  (samtools index)
  ├── AaegL5.dict        (sequence dictionary)
  ├── AaegL5.fasta.bwt  (BWA index)
  ├── AaegL5.fasta.ann
  ├── AaegL5.fasta.amb
  ├── AaegL5.fasta.pac
  └── AaegL5.fasta.sa
```

Parabricks uses standard BWA v0.7.x indices, not BWA-mem2.

## References

- [parabricks-omics-private-workflows](https://github.com/clara-parabricks-workflows/parabricks-omics-private-workflows) — NVIDIA's official HealthOmics GPU workflows
- [Parabricks fq2bam](https://docs.nvidia.com/clara/parabricks/4.0.1/documentation/tooldocs/man_fq2bam.html) — Tool reference
- [Parabricks haplotypecaller](https://docs.nvidia.com/clara/parabricks/4.0.1/documentation/tooldocs/man_haplotypecaller.html) — Tool reference
- [NGC container registry](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/clara/containers/nvidia_clara_parabricks_amazon_linux) — Amazon Linux variant
