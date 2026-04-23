# Test Results — Aedes aegypti WGS Pipeline

**Date:** 2026-04-14 ~ 2026-04-17  
**Sample:** SRR6063611 (Aedes aegypti, paired-end WGS, NextSeq 500, ~98M read pairs)  
**Reference:** AaegL5 (GCF_002204515.2, 1.279 Gb, 3 chromosomes + 2,307 scaffolds)

---

## 1. Simulated Data Test (EC2)

A quick validation run using simulated reads (wgsim) confirmed pipeline correctness before real data.

| Step | Tool | Result |
|---|---|---|
| Simulate reads | wgsim | 2x 100K reads generated |
| QC | FastQC + FastP | PASS |
| Alignment | BWA-mem2 | PASS |
| Sort & Index | samtools | PASS |
| Mark Duplicates | GATK MarkDuplicates | PASS |
| Variant Calling | GATK HaplotypeCaller | gVCF generated |
| Joint Genotyping | GATK GenomicsDBImport + GenotypeGVCFs | VCF generated |
| Filtering | bcftools | Filtered VCF generated |

---

## 2. Real Data — EC2 Run (SRR6063611)

**Platform:** EC2 m5.2xlarge (8 vCPU, 32 GiB, Intel Xeon Platinum 8175M)  
**Date:** 2026-04-14 ~ 2026-04-15

### 2.1 Pipeline Execution

| Task | Tool | Duration | Output |
|---|---|---:|---|
| QC (raw) | FastQC 0.12.1 | ~15 min | HTML reports |
| Trimming | FastP | ~15 min | Trimmed FASTQ (Q20, min 50bp) |
| Alignment | BWA-mem2 2.2.1 (AVX-512BW) | ~90 min | 30 GB aligned BAM |
| Sort & Index | samtools 1.20 | ~15 min | Sorted BAM + BAI |
| Mark Duplicates | GATK 4.5.0.0 MarkDuplicates | ~30 min | Deduped BAM |
| Variant Calling | GATK 4.5.0.0 HaplotypeCaller | ~588 min (9.8h) | 6.8 GB gVCF |
| **Total** | | **~753 min (12.6h)** | |

### 2.2 gVCF Verification

| Metric | Value |
|---|---|
| File size | 6.8 GB (.g.vcf.gz) + 1.7 MB (.tbi) |
| Sample name | SRR6063611 |
| Contigs with variants | 2,310 (3 chromosomes + scaffolds) |
| SNPs in first 1 Mb of chr1 | 650 |
| Format | GVCF with `<NON_REF>` blocks, GT:DP:GQ:MIN_DP:PL |
| S3 upload | Confirmed |

### 2.3 Issues Encountered

| Issue | Root Cause | Fix |
|---|---|---|
| BWA-mem2 crashed at task 38 | SSM default `executionTimeout` = 3600s | Set `executionTimeout` explicitly |
| BWA-mem2 SIMD binary not found | Symlink at `/usr/local/bin/` breaks sibling lookup | Use full path `/opt/bwa-mem2-2.2.1_x64-linux/bwa-mem2` |
| HaplotypeCaller killed at 12h | SSM `executionTimeout` = 43200s too short | Created standalone HC script with 86400s timeout |

---

## 3. Real Data — HealthOmics Run (SRR6063611)

**Platform:** AWS HealthOmics Private Workflow (Run ID: 6185205, Workflow ID: 3734360)  
**Date:** 2026-04-16 ~ 2026-04-17  
**Storage:** Dynamic (43 GiB peak)

### 3.1 Pipeline Execution

| Task | Instance Type | Duration | Status |
|---|---|---:|---|
| FastQC | omics.c.large (2 vCPU, 4 GiB) | 18 min | COMPLETED |
| FastP | omics.c.xlarge (4 vCPU, 8 GiB) | 12 min | COMPLETED |
| BWA-mem2 Align | omics.m.2xlarge (8 vCPU, 32 GiB) | 482 min (8.0h) | COMPLETED |
| SortAndIndex | omics.m.xlarge (4 vCPU, 16 GiB) | 16 min | COMPLETED |
| MarkDuplicates | omics.r.xlarge (2 vCPU, 32 GiB) | 34 min | COMPLETED |
| HaplotypeCaller | omics.m.xlarge (4 vCPU, 16 GiB) | 1,080 min (18.0h) | COMPLETED |
| **Total wall-clock** | | **~1,642 min (27.4h)** | **COMPLETED** |

### 3.2 Failed Run (v1, Run ID: 9401849)

| Issue | Cause | Fix |
|---|---|---|
| BwaAlign terminated after 46 sec | `ln -sf` into read-only localized directory | Stage reference files to writable `/tmp/ref` |
| ECR access denied on `start-run` | Missing ECR repository policy for `omics.amazonaws.com` | Added ECR resource-based policy |

### 3.3 Docker Image

| Component | Version |
|---|---|
| Base | broadinstitute/gatk:4.5.0.0 |
| BWA-mem2 | 2.2.1 |
| FastQC | 0.12.1 |
| FastP | latest (binary) |
| BCFtools | 1.20 |
| samtools | (included in GATK base image) |

---

## 4. EC2 vs HealthOmics Comparison

### 4.1 Runtime

| Task | EC2 | HealthOmics | Ratio |
|---|---:|---:|---:|
| FastQC | ~15 min | 18 min | 1.2x |
| FastP | ~15 min | 12 min | 0.8x |
| **BWA-mem2** | **90 min** | **482 min** | **5.4x** |
| SortAndIndex | ~15 min | 16 min | 1.1x |
| MarkDuplicates | ~30 min | 34 min | 1.1x |
| **HaplotypeCaller** | **588 min** | **1,080 min** | **1.8x** |
| **Total** | **~753 min** | **~1,642 min** | **2.2x** |

### 4.2 Estimated Cost per Sample

| Component | HealthOmics | EC2 (m5.2xlarge on-demand) |
|---|---:|---:|
| Compute | $10.09 | $6.22 |
| Storage | $0.37 | $0.79 |
| **Total** | **~$10.46** | **~$7.02** |

### 4.3 Root Cause of Performance Gap

**BWA-mem2 (5.4x slower):** SIMD instruction set degradation. EC2 m5.2xlarge confirmed using AVX-512BW; HealthOmics instance lacks AVX-512 (likely SSE4.1/4.2 fallback). Evidence:
- Only BWA-mem2 (SIMD-dependent) shows large slowdown
- I/O-heavy tasks (SortAndIndex, MarkDuplicates) show only 1.1x
- 5.4x matches known AVX-512 → SSE4.x performance degradation

**HaplotypeCaller (1.8x slower):** General CPU performance gap (clock speed / microarchitecture). HC is single-threaded and SIMD-independent.

### 4.4 Key Insight

If HealthOmics instances supported AVX-512 (or equivalent SIMD), the platform's per-task billing model would make it **~16% cheaper than EC2** for this workload. The current cost premium (+49%) is driven entirely by the CPU performance gap on compute-intensive tasks.

---

## 5. HealthOmics Deployment Artifacts

| Artifact | Description |
|---|---|
| `workflows/gatk/Dockerfile` | Docker image with GATK 4.5 + BWA-mem2 + FastQC + FastP + BCFtools |
| `workflows/gatk/gatk-mosquito.wdl` | WDL workflow for per-sample variant calling |
| `workflows/gatk/joint-genotyping.wdl` | WDL workflow for joint genotyping |
| `workflows/gatk/omics-trust-policy.json` | IAM trust policy for HealthOmics service role |
| `workflows/gatk/omics-permissions-policy.json` | IAM permissions (S3, ECR, CloudWatch) |
| `workflows/gatk/run-inputs-SRR6063611.json` | Example run input parameters |
