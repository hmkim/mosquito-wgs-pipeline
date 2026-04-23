# AWS HealthOmics Private Workflow Performance Report

**Project:** NEA/EHI Aedes aegypti Whole-Genome Sequencing Pipeline  
**Region:** ap-northeast-2 (Seoul)  
**Date:** 2026-04-16  
**Sample:** SRR6063611 (Aedes aegypti, paired-end WGS, ~160M reads, ~19 GB FASTQ)

---

## 1. Overview

We deployed a GATK best-practices WGS pipeline (FastQC > FastP > BWA-mem2 > SortAndIndex > MarkDuplicates > HaplotypeCaller) on both **EC2** and **AWS HealthOmics Private Workflows** to evaluate HealthOmics as our production platform. The same Docker image and identical input data were used on both platforms.

Significant performance anomalies were observed in the **BWA-mem2 alignment task (5.4x slower)** and **HaplotypeCaller (1.8x slower)**, while all other tasks performed comparably between the two platforms. The run completed successfully on HealthOmics on 2026-04-17.

## 2. Environment

| Component | EC2 | HealthOmics |
|---|---|---|
| Instance | m5.2xlarge (8 vCPU, 32 GiB) | omics.m.2xlarge (8 vCPU, 32 GiB) |
| CPU | Intel Xeon Platinum 8175M @ 2.50GHz | Not disclosed |
| SIMD support | AVX-512BW confirmed | Not available for inspection |
| Docker image | `nea-ehi-gatk:latest` (GATK 4.5.0.0 + BWA-mem2 2.2.1) | Same image via ECR |
| Storage | EBS gp3 (500 GiB) | Dynamic run storage (43 GiB peak) |
| Run ID | N/A (SSM-managed) | 6185205 (Workflow ID: 3734360) |

## 3. Per-Task Runtime Comparison

| Task | HealthOmics Instance | EC2 Duration | HealthOmics Duration | Ratio |
|---|---|---:|---:|---:|
| FastQC | omics.c.large (2 vCPU, 4 GiB) | ~15 min | 18 min | 1.2x |
| FastP | omics.c.xlarge (4 vCPU, 8 GiB) | ~15 min | 12 min | 0.8x |
| **BWA-mem2 Align** | **omics.m.2xlarge (8 vCPU, 32 GiB)** | **90 min** | **482 min** | **5.4x** |
| SortAndIndex | omics.m.xlarge (4 vCPU, 16 GiB) | ~15 min | 16 min | 1.1x |
| MarkDuplicates | omics.r.xlarge (2 vCPU, 32 GiB) | ~30 min | 34 min | 1.1x |
| **HaplotypeCaller** | **omics.m.xlarge (4 vCPU, 16 GiB)** | **588 min** | **1,080 min** | **1.8x** |
| **Total wall-clock** | | **~753 min (12.6h)** | **~1,642 min (27.4h)** | **2.2x** |

**Key observations:**
- BWA-mem2 exhibits the largest slowdown (5.4x), consistent with SIMD instruction set degradation (see Section 5).
- HaplotypeCaller is 1.8x slower, indicating a general CPU performance gap (clock speed or microarchitecture) beyond SIMD, since HaplotypeCaller is single-threaded and does not use SIMD.
- All other tasks (FastP, FastQC, SortAndIndex, MarkDuplicates) run within 0.8x–1.2x of EC2 performance.

## 4. Cost Impact

### 4.1 Estimated Per-Task Cost

Prices estimated based on published US East-1 rates with 1.1x regional adjustment for ap-northeast-2.

| Task | HealthOmics Instance | HealthOmics Cost | EC2 Cost | Difference |
|---|---|---:|---:|---:|
| FastQC | omics.c.large | $0.04 | $0.12 | -68% |
| FastP | omics.c.xlarge | $0.05 | $0.12 | -58% |
| **BWA-mem2 Align** | **omics.m.2xlarge** | **$4.58** | **$0.74** | **+519%** |
| SortAndIndex | omics.m.xlarge | $0.08 | $0.12 | -33% |
| MarkDuplicates | omics.r.xlarge | $0.21 | $0.25 | -16% |
| **HaplotypeCaller** | **omics.m.xlarge** | **$5.13** | **$4.86** | **+6%** |
| Dynamic Storage | - | $0.37 | $0.79 (EBS) | -53% |
| **Total per sample** | | **~$10.46** | **~$7.02** | **+49%** |

### 4.2 Cost Breakdown

- BWA-mem2 alone accounts for **$4.58 / $10.46 = 44%** of total HealthOmics run cost.
- BWA-mem2 + HaplotypeCaller together account for **$9.71 / $10.46 = 93%** of total cost.
- If BWA-mem2 ran at EC2-equivalent speed (~90 min instead of 482 min), its cost would be ~$0.86, bringing the total HealthOmics cost to **~$6.74** — approximately **4% cheaper than EC2**.
- If both BWA-mem2 and HaplotypeCaller ran at EC2-equivalent speed, the total would be **~$5.88** — approximately **16% cheaper than EC2**.

### 4.3 Failed Run Cost

An earlier run (ID: 9401849) failed at BwaAlign due to a read-only filesystem issue (since resolved). Wasted cost: **~$0.11** (negligible).

## 5. Root Cause Analysis

### 5.1 Confirmed: EC2 SIMD Capability

BWA-mem2 binary selection was verified on the EC2 instance (both host and inside Docker):

```
$ /opt/bwa-mem2-2.2.1_x64-linux/bwa-mem2 version
Looking to launch executable "bwa-mem2.avx512bw", simd = .avx512bw
Launching executable "bwa-mem2.avx512bw"
2.2.1
```

EC2 CPU flags confirm full AVX-512 support:
```
avx, avx2, avx512bw, avx512cd, avx512dq, avx512f, avx512vl, sse4_1, sse4_2
```

### 5.2 HealthOmics: SIMD Level Unknown

HealthOmics does not expose task-level stdout/stderr in CloudWatch logs, so we cannot directly confirm which BWA-mem2 SIMD binary was selected. However, the runtime data provides strong indirect evidence:

**Why SIMD is the most likely cause:**

1. **Only BWA-mem2 is affected.** BWA-mem2 is the only tool in the pipeline that relies heavily on SIMD vectorized instructions (FM-index search, Smith-Waterman alignment). All other tools (FastP, samtools, GATK) do not use SIMD significantly.

2. **I/O is not the bottleneck.** SortAndIndex and MarkDuplicates are the most I/O-intensive tasks (each reads and writes ~30 GB BAM files), yet they show only 1.1x slowdown. BWA-mem2's I/O pattern (streaming reads, one-time index load) is lighter.

3. **The 5.4x ratio matches known SIMD degradation.** BWA-mem2's published benchmarks show:
   - AVX-512 to AVX2: ~1.3x slowdown
   - AVX-512 to SSE4.2: ~3-4x slowdown
   - AVX-512 to SSE4.1: ~5-6x slowdown

   The observed 5.4x is consistent with SSE4.1 or SSE4.2 fallback.

4. **HaplotypeCaller's 1.8x slowdown reveals a secondary CPU performance gap.** HC is single-threaded and does not use SIMD, so its slowdown indicates that HealthOmics instances also have lower single-thread CPU performance (clock speed or microarchitecture). However, this 1.8x gap is far smaller than BWA-mem2's 5.4x, confirming that SIMD is the dominant factor for BWA-mem2.

5. **I/O-heavy tasks are unaffected.** SortAndIndex and MarkDuplicates (each reading/writing ~30 GB BAM) show only 1.1x slowdown, ruling out storage I/O as a factor.

### 5.3 Summary of Evidence

| Hypothesis | Expected Pattern | Observed | Verdict |
|---|---|---|---|
| I/O bottleneck (EBS vs HealthOmics storage) | I/O-heavy tasks (Sort, MarkDup) most affected | Sort/MarkDup: 1.1x; BWA: 5.4x | **Rejected** |
| General CPU performance (clock, generation) | All tasks proportionally slower | Most tasks 1.0-1.2x; HC 1.8x; BWA 5.4x | **Partial** — explains HC but not BWA gap |
| SIMD instruction set degradation | Only SIMD-dependent tools affected | BWA-mem2 (SIMD-dependent) is 5.4x slower; non-SIMD tasks 1.0-1.8x | **Primary cause for BWA-mem2** |
| Combined: SIMD + lower CPU clock | BWA-mem2 >> HC >> other tasks | BWA 5.4x > HC 1.8x > others 1.1x | **Best fit** |

## 6. Questions for the HealthOmics Team

1. **What CPU type and SIMD instruction sets are available on `omics.m.*` instance types in ap-northeast-2?** Specifically, do they support AVX2 or AVX-512?

2. **Is there a way to select instance families with specific CPU capabilities** (e.g., Intel AVX-512 vs. Graviton ARM)?

3. **Can task-level stdout/stderr be exposed in CloudWatch logs?** Currently only run-level orchestration logs are available, making it difficult to debug task failures and performance issues.

4. **Are there plans to offer compute-optimized instances with AVX-512 support** for alignment-heavy genomics workloads?

## 7. Potential Workarounds

| Approach | Description | Trade-off |
|---|---|---|
| Use original `bwa mem` (v0.7.x) | Not SIMD-dependent; consistent speed across platforms | ~2-3x slower than BWA-mem2 on AVX-512, but may be faster on HealthOmics than BWA-mem2 without AVX |
| Use `minimap2` | Lower SIMD dependency; widely validated for WGS | Requires revalidation of downstream variant calling |
| Hybrid architecture | Run BWA-mem2 on EC2 (AVX-512), remaining tasks on HealthOmics | Operational complexity; data transfer between platforms |
| Request instance type guidance | Work with AWS SA to identify HealthOmics instances with AVX-512 | Depends on HealthOmics instance fleet |

---

*Report prepared by NEA/EHI POC Team. HealthOmics cost estimates are based on published pricing and may differ from actual billing.*
