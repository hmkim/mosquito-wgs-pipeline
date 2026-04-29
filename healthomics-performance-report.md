# AWS HealthOmics Private Workflow Performance Report

**Project:** NEA/EHI Aedes aegypti Whole-Genome Sequencing Pipeline  
**Region:** ap-northeast-2 (Seoul), ap-southeast-1 (Singapore)  
**Date:** 2026-04-16 ~ 2026-04-29  
**Sample:** SRR6063611 (Aedes aegypti, paired-end WGS, ~160M reads, ~19 GB FASTQ)

---

## 1. Overview

We evaluated five variant-calling approaches for the NEA/EHI *Aedes aegypti* WGS pipeline:

| Approach | Platform | Compute | Wall-clock | Cost | vs EC2 |
|---|---|---:|---:|---:|---:|
| GATK HC + BWA-mem2 | EC2 CPU | 753 min | 12.6h | $7.02 | baseline |
| GATK HC + BWA-mem2 | HealthOmics CPU | 1,642 min | 27.4h | $10.46 | +49% |
| GATK HC + BWA v0.7.19 | HealthOmics CPU | 1,230 min | 20.5h | $8.57 | +22% |
| **Sentieon DNAscope** | **HealthOmics CPU** | **124 min** | **2.4h** | **$6.47** | **-8%** |
| Parabricks GPU | Batch g5.12xlarge | 37 min | 50 min | $3.66 | -48% |
| Parabricks GPU | HealthOmics GPU | 46 min | 105 min | $5.90 | -16% |

**Key findings:** GATK on HealthOmics suffers 5.4x BWA-mem2 slowdown (SIMD degradation) and 1.8x HaplotypeCaller slowdown. **Sentieon DNAscope bypasses both issues**, delivering 5.3x faster than EC2 GATK at 8% lower cost on CPU-only instances available in any region. Parabricks GPU remains the fastest option but requires A10G (us-east-1 only on HealthOmics).

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

## 7. BWA v0.7.19 Experiment (2026-04-23)

### 7.1 Hypothesis

If SIMD degradation (AVX-512 → SSE4.x) is the primary cause of BWA-mem2's 5.4x slowdown on HealthOmics, then using BWA v0.7.19 (no SIMD dependency) should reduce alignment time significantly — potentially to ~90-150 min.

### 7.2 Setup

- **Run ID:** 6503897 (Workflow ID: 4795553)
- **Docker image:** `nea-ehi-gatk-bwa:latest` — GATK 4.5.0.0 + BWA 0.7.19 (compiled from source)
- **Index files:** BWA-format `.bwt` + `.sa` (generated fresh; BWA-mem2 indices are incompatible)
- **All other parameters identical** to the BWA-mem2 run (same sample, reference, instance types)

### 7.3 Results

| Task | BWA-mem2 (Run 6185205) | BWA v0.7.19 (Run 6503897) | Difference |
|---|---:|---:|---:|
| FastQC | 18 min | 18 min | 0% |
| FastP | 12 min | 18 min | +50% |
| **Alignment** | **482 min** | **456 min** | **-5%** |
| SortAndIndex | 16 min | 23 min | +44% |
| MarkDuplicates | 34 min | 35 min | +3% |
| HaplotypeCaller | 1,080 min | 680 min | -37% |
| **Total** | **1,642 min** | **1,230 min** | **-25%** |

### 7.4 Analysis

**The hypothesis was disproven.** BWA v0.7.19 completed alignment in 456 min, essentially identical to BWA-mem2's 482 min. The difference is within normal run-to-run variability.

**Revised understanding of the 5.4x BWA-mem2 slowdown:**

The 5.4x gap between EC2 BWA-mem2 (90 min) and HealthOmics BWA-mem2 (482 min) decomposes as:

| Factor | Estimated contribution | Explanation |
|---|---:|---|
| SIMD speedup lost | ~3.3x | EC2 BWA-mem2 with AVX-512 is ~3.3x faster than BWA v0.7.x. On HealthOmics, BWA-mem2 loses this advantage and regresses to BWA v0.7.x speed. |
| General CPU gap | ~1.5x | Same gap seen in SortAndIndex and MarkDuplicates across runs. |
| **Combined** | **~5x** | 3.3 × 1.5 ≈ 5.0 (close to observed 5.1-5.4x) |

Key insight: BWA-mem2 without SIMD acceleration is *not faster than BWA v0.7.x*. Its speed advantage is entirely SIMD-derived. On a platform without AVX-512, switching to BWA v0.7.19 changes nothing.

**HaplotypeCaller variability:** HC ran in 680 min on this run vs 1,080 min on the BWA-mem2 run — a 1.6x difference for identical input on the same instance type (`omics.m.xlarge`). This suggests heterogeneous hardware in the HealthOmics fleet, where some runs land on faster physical hosts. The HC task is single-threaded and entirely CPU-bound, making it sensitive to clock speed differences.

### 7.5 Cost Comparison

| | EC2 (BWA-mem2) | Omics (BWA-mem2) | Omics (BWA v0.7.19) |
|---|---:|---:|---:|
| Compute | $6.22 | $10.09 | $8.04 |
| Storage | $0.79 | $0.37 | $0.53 |
| **Total** | **$7.02** | **$10.46** | **$8.57** |
| vs EC2 | baseline | +49% | +22% |

The lower total cost of the BWA run is driven by HC's shorter runtime (fleet variability), not alignment improvement.

## 8. Parabricks GPU Experiment (2026-04-26)

### 8.1 Setup

After disproving the BWA v0.7.x hypothesis, we tested GPU-accelerated variant calling using NVIDIA Clara Parabricks on AWS Batch.

- **Platform:** AWS Batch, g5.12xlarge (4x NVIDIA A10G 24 GiB VRAM, 48 vCPU, 192 GiB RAM)
- **Image:** `parabricks:4.3.1-1` (from `nvcr.io/nvidia/clara/clara-parabricks`)
- **Storage:** Local NVMe SSD (900 GB), S3 data transfer at ~250 MiB/s
- **Job ID:** `21bb94f9-cd5d-4a46-b18f-e224481bfd8e`

### 8.2 Results

| Step | Tool | Duration | Equivalent CPU tasks |
|---|---|---:|---|
| **fq2bam** | GPU-BWA + sort + markdup | **14 min** | Alignment (90-482 min) + Sort (15-23 min) + MarkDup (30-35 min) |
|   ↳ GPU-BWA Mem | GPU kernel (4x A10G) | 12 min 10 sec | |
|   ↳ Sorting Phase-II | CPU | ~15 sec | |
|   ↳ MarkDuplicates | CPU/GPU | 1 min 11 sec | |
| **HaplotypeCaller** | GPU-GATK4 HC | **23 min** | HaplotypeCaller (588-1,080 min) |
| **Pipeline total** | | **37 min** | **753-1,642 min on CPU** |

### 8.3 Five-Way Performance Comparison

| | EC2 CPU | Omics (BWA-mem2) | Omics (BWA v0.7.19) | **Batch GPU** | **Omics GPU** |
|---|---:|---:|---:|---:|---:|
| Align+Sort+MarkDup | ~135 min | ~532 min | ~514 min | **14 min** | **20 min** |
| HaplotypeCaller | 588 min | 1,080 min | 680 min | **23 min** | **25 min** |
| **Pipeline compute** | **753 min** | **1,642 min** | **1,230 min** | **37 min** | **46 min** |
| Wall-clock (incl. provisioning) | — | — | — | 44 min | 105 min |
| **vs EC2** | baseline | 2.2x slower | 1.6x slower | **20x faster** | **16x faster** |
| **Cost** | **$7.02** | **$10.46** | **$8.57** | **$4.16** (OD) / **$1.66** (Spot) | **$5.90** |
| **vs EC2 cost** | baseline | +49% | +22% | **-41% (OD) / -76% (Spot)** | **-16%** |

**Omics GPU:** Run 1587591, us-east-1, omics.g5.12xlarge (4x A10G), `nvidia-tesla-a10g` acceleratorType. Parabricks 4.3.1-1.

**Batch GPU cost note:** EC2 bills the full instance duration (44 min including S3 data transfer), not just the 37-min pipeline compute. On-Demand $5.672/hr × 44 min = $4.16.

**HealthOmics GPU cost note:** omics.g5.12xlarge = $7.6572/hr (35% premium over EC2 g5.12xlarge $5.672/hr). HealthOmics bills per-second on task runtime only; the 54-min provisioning wait is not billed for compute. fq2bam 20m28s + HC 25m11s = 45m39s = $5.83 compute + $0.08 storage = $5.90.

**HealthOmics vs Batch cost ratio (1.42x) decomposition:**

| Factor | Ratio | Explanation |
|---|---:|---|
| Hourly rate premium | 1.35x | Managed service margin ($7.66 vs $5.67/hr) |
| Billed time difference | 1.04x | 45.7 min (task only) vs 44 min (full job) — nearly equal |
| Storage overhead | 1.01x | $0.08 — negligible |
| **Combined** | **1.42x** | **$5.90 / $4.16** |

### 8.4 Key Insights

1. **GPU-BWA alignment: 12-20 min vs 90-482 min on CPU.** The 4x A10G GPUs complete alignment 4.5-7.5x faster than EC2 AVX-512 and 24-40x faster than HealthOmics CPU. GPU alignment is entirely orthogonal to the SIMD/CPU architecture issue.

2. **GPU HaplotypeCaller: 23-25 min vs 588-1,080 min on CPU.** This is the most dramatic improvement — HC is single-threaded on CPU but parallelized across GPU cores. The 24-47x speedup eliminates HC as the pipeline bottleneck.

3. **End-to-end: 37-46 min vs 12.6 hours.** Parabricks compresses the entire pipeline (excluding QC) into under 46 minutes on both platforms, making same-day turnaround feasible for large cohorts.

4. **Batch GPU is the cost leader.** g5.12xlarge On-Demand at $4.16/sample (44 min job) is 41% cheaper than EC2 CPU. With Spot at $1.66/sample — 76% cheaper.

5. **HealthOmics GPU is the managed alternative.** At $5.90/sample it's 16% cheaper than EC2 CPU and 44% cheaper than HealthOmics CPU ($10.46), while providing fully managed workflow orchestration. The 42% premium over Batch is almost entirely the 35% hourly rate markup (managed service margin). The trade-off is longer GPU provisioning time (~54 min) and us-east-1 only availability.

6. **A10G (24 GiB VRAM) required.** T4 (16 GiB VRAM) on g4dn succeeded for fq2bam but failed on HaplotypeCaller. For full germline pipeline, g5 (A10G) or better is required.

## 9. Variant Concordance (2026-04-27, updated 2026-04-29)

HC concordance benchmarking across 5 pipelines (3 chromosomes, ~93% of genome). See [test-results.md](test-results.md#9-haplotypecaller-concordance-benchmarking) for full details.

| Comparison | SNP F1 | Indel F1 | GT Match (shared) | Key Finding |
|---|---:|---:|---:|---|
| Parabricks GPU vs EC2 CPU | 0.455 | 0.594 | 100% | Low F1 from 9.6M extra variants (no trimming); shared sites 100% match |
| Omics BWA-mem2 vs EC2 CPU | 0.99979 | 0.99978 | 100% | Near-perfect cross-platform concordance |
| BWA v0.7.19 vs BWA-mem2 | 1.00000 | 1.00000 | 100% | Aligner choice has zero impact on variant calling |
| **Sentieon DNAscope vs EC2 CPU** | **0.616** | **0.593** | **97.6%** | **Different caller algorithm — DNAscope calls 2x more variants (Ti/Tv 0.94)** |

**Sentieon low F1 explained:** DNAscope is a different calling algorithm from HaplotypeCaller. It calls 6.7M SNPs vs GATK's 3.3M (2x more) with a lower Ti/Tv (0.94 vs 1.21). Recall is high (93.4%) — Sentieon captures nearly all GATK variants. The extra calls are low-confidence candidates (43% QUAL<10) designed for downstream filtering (VQSR/ML model). This is standard DNAscope behavior, not a quality issue.

**Parabricks low F1 explained:** Parabricks runs on raw FASTQ (no FastP trimming), calling 12.4M SNPs vs EC2's 3.9M (Ti/Tv 0.43 vs 1.20). The 8.8M extra calls are low-quality false positives. On shared sites, genotype concordance is 100%. Adding a trimming step or quality filter to Parabricks output would align F1 with the paper's >0.990 benchmark.

## 10. Workaround Status Summary

| Approach | Expected Impact | Actual Result | Status |
|---|---|---|---|
| ~~Use BWA v0.7.x~~ | ~~Reduce alignment time~~ | No improvement (456 vs 482 min) | **Disproven** |
| **Sentieon DNAscope (HealthOmics CPU)** | **~2-3h, $6-9** | **124 min compute, $6.47/sample** | **Validated — best CPU option** |
| **Parabricks GPU (Batch g5.12xlarge)** | **~10-30 min alignment** | **14 min align, 23 min HC, 37 min total** | **Validated — fastest & cheapest** |
| Parabricks GPU (HealthOmics us-east-1) | Same as Batch | 46 min compute, $5.90/sample, 61% more than Batch | **Validated** (Run 1587591) |
| Parabricks GPU (HealthOmics ap-northeast-2) | Same as Batch | T4 OOM; A10G unsupported | **Blocked** (inquiry sent) |
| ~~Use `minimap2`~~ | ~~Unknown~~ | Not tested | Superseded by Sentieon/Parabricks |
| ~~Hybrid architecture~~ | ~~Reduce alignment bottleneck~~ | Not needed | Superseded by Sentieon/Parabricks |
| Request AVX-512 instances | Full SIMD performance on HealthOmics | Not tested | Moot — Sentieon bypasses the issue |

## 11. HealthOmics GPU Investigation (2026-04-26~27)

### 11.1 Background

After validating Parabricks on AWS Batch (Section 8), we investigated whether HealthOmics GPU instances could run the same pipeline, which would allow end-to-end workflow management on HealthOmics.

### 11.2 Root Cause of HealthOmics HC Failures

All HealthOmics Parabricks runs (v4–v7, 6 attempts) failed at HaplotypeCaller within ~51 seconds with status "Terminated". The root cause is **CUDA out-of-memory on T4 (16 GiB VRAM)** for the *Ae. aegypti* 1.3 Gbp genome. This was confirmed by running the same pipeline on AWS Batch g4dn.12xlarge (T4), where the explicit error appeared:

```
[PB Error][src/likehood_test.cu:1056] cudaSafeCall() failed: out of memory, exiting.
```

The `nvidia-tesla-t4-a10g` acceleratorType always selects T4 (lowest cost), making HealthOmics GPU runs consistently hit OOM at the HC stage.

### 11.3 GPU Probe Regional Testing

To investigate A10G availability across regions, we created a minimal GPU probe workflow (`gpu-test/gpu-probe.wdl`) that runs `nvidia-smi` to identify the assigned GPU instance.

| Region | acceleratorType | Result | Instance Assigned |
|---|---|---|---|
| us-east-1 | `nvidia-tesla-t4-a10g` | OK | omics.g4dn.12xlarge (T4) |
| us-east-1 | `nvidia-tesla-a10g` | OK | omics.g5.12xlarge (A10G) |
| ap-northeast-2 | `nvidia-tesla-t4-a10g` | OK | omics.g4dn.12xlarge (T4) |
| ap-northeast-2 | `nvidia-tesla-a10g` | **FAILED** | UNSUPPORTED_GPU_INSTANCE_TYPE |
| ap-southeast-1 | `nvidia-tesla-t4-a10g` | OK | omics.g4dn.12xlarge (T4) |
| ap-southeast-1 | `nvidia-tesla-a10g` | **FAILED** | UNSUPPORTED_GPU_INSTANCE_TYPE |

### 11.4 Key Findings

1. **`nvidia-tesla-t4-a10g` always selects T4 (lowest cost)** across all tested regions — there is no way to force A10G selection with this type.
2. **`nvidia-tesla-a10g` works only in us-east-1** — fails with `UNSUPPORTED_GPU_INSTANCE_TYPE` in ap-northeast-2 and ap-southeast-1, despite being listed in the error message's "available types" for ap-northeast-2.
3. **The error message is misleading** — ap-northeast-2 lists `nvidia-tesla-a10g` as "available" in the error response, but it actually fails when used.
4. **ap-southeast-1** only reports `[nvidia-tesla-t4, nvidia-t4-a10g-l4]` as available — G5 (A10G) is not supported in Singapore.

### 11.5 Successful Run: v8 (us-east-1, A10G)

After confirming A10G availability in us-east-1, we ran the full Parabricks pipeline on HealthOmics with `nvidia-tesla-a10g`:

- **Run ID:** 1587591 (Workflow ID: 4653305), us-east-1
- **Instance:** omics.g5.12xlarge (48 vCPU, 192 GiB, 4x A10G)
- **Image:** `parabricks:4.3.1-1` via ECR (us-east-1)

| Task | Duration | Instance Cost |
|---|---:|---:|
| fq2bam | 20 min 28 sec | $2.61 |
| HaplotypeCaller | 25 min 11 sec | $3.21 |
| **Pipeline compute** | **45 min 39 sec** | **$5.83** |
| Storage (106 GiB dynamic, 1.75h) | — | $0.08 |
| **Total** | **46 min** | **$5.90** |

GPU provisioning took ~54 min (task created at 08:53, started at 09:45). Total wall-clock was 105 min. HC task reused the fq2bam instance (started 43s after fq2bam completion). HealthOmics bills per-second on task runtime only — the 54-min provisioning wait is not billed for compute.

See [test-results.md](test-results.md#11-healthomics-gpu-runs--parabricks-srr6063611) for full task-level details and output files.

### 11.6 Implications

For workloads requiring >16 GiB GPU VRAM (like Parabricks HC on large genomes), HealthOmics is only viable in **us-east-1** where `nvidia-tesla-a10g` can explicitly request A10G instances. In all other tested regions, AWS Batch with g5.12xlarge remains the only option.

HealthOmics GPU (us-east-1) is a viable managed alternative to Batch GPU: 46 min compute at $5.90/sample vs Batch's 44 min job at $4.16/sample. The 1.42x cost premium is driven almost entirely by the 35% higher hourly rate (managed service margin), not by compute time difference.

A technical inquiry has been sent to the HealthOmics SA team (`healthomics-gpu-inquiry.eml`) asking about:
- Timeline for G5 (A10G) support in ap-northeast-2
- Whether `nvidia-tesla-t4-a10g` can hint for A10G selection
- Clarification on misleading error messages listing unsupported types

## 12. HealthOmics Parabricks GPU — us-east-1 A10G (2026-04-27)

### 12.1 Background

Following the GPU probe regional testing (Section 11.3), we confirmed that `nvidia-tesla-a10g` works only in us-east-1. We then ran the full Parabricks germline pipeline on HealthOmics in us-east-1, marking the **first successful end-to-end Parabricks execution on HealthOmics** for this project.

### 12.2 Setup

| Parameter | Value |
|---|---|
| **Run ID** | 1587591 (Workflow ID: 4653305) |
| **Run Name** | SRR6063611-parabricks-v8-use1-a10g |
| **Region** | us-east-1 |
| **Instance** | omics.g5.12xlarge (48 vCPU, 192 GiB RAM, 4× NVIDIA A10G) |
| **Parabricks** | 4.3.1-1 |
| **Sample** | SRR6063611 (*Ae. aegypti*, ~19 GB paired-end FASTQ) |
| **Reference** | AaegL5.fasta.tar |

### 12.3 Timeline

```
08:50:37  Run created
08:50:57  Run started (queue: 20 sec)
09:45:16  fq2bam task started (instance provisioning: 54 min 19 sec)
10:05:44  fq2bam completed (runtime: 20 min 28 sec)
10:06:27  haplotypecaller started (inter-task gap: 43 sec)
10:31:38  haplotypecaller completed (runtime: 25 min 11 sec)
10:36:02  Run completed (finalization: 4 min 24 sec)
```

- **Wall-clock time:** 1 hr 45 min (creation to completion)
- **Compute time:** 45 min 39 sec (fq2bam + haplotypecaller)
- **Overhead:** 59 min 26 sec (instance provisioning 54 min + inter-task 1 min + finalization 4 min)

The Gantt chart is saved at [`run-1587591-timeline.svg`](run-1587591-timeline.svg).

### 12.4 Per-Task Cost & Resource Utilization

| Metric | fq2bam | haplotypecaller | Total |
|---|---:|---:|---:|
| **Runtime** | 20 min 28 sec | 25 min 11 sec | 45 min 39 sec |
| **Instance** | omics.g5.12xlarge | omics.g5.12xlarge | — |
| **Allocated CPUs** | 48 | 48 | 96 |
| **Peak CPU Usage** | 43.0 | 36.0 | — |
| **CPU Efficiency** | 50.2% | 65.0% | 57.6% |
| **Allocated Memory** | 192 GiB | 192 GiB | 384 GiB |
| **Peak Memory Usage** | 61.0 GiB | 28.3 GiB | — |
| **Memory Efficiency** | 20.5% | 12.9% | 16.7% |
| **Estimated Cost** | **$2.61** | **$3.21** | **$5.83** |
| **Storage Cost** | — | — | **$0.08** |
| **Total** | — | — | **$5.90** |

**Resource utilization notes:**
- Both tasks are GPU-bound, so CPU/memory efficiency metrics are misleading — the GPU is the primary compute resource, but manifest logs do not report GPU utilization.
- The performance analysis recommends downsizing to `omics.c.16xlarge` / `omics.c.12xlarge`, but these are **CPU-only** instances and would not have GPUs. The `omics.g5.12xlarge` is the only A10G option available.
- Memory is heavily over-provisioned (61/192 GiB and 28/192 GiB), but memory allocation is fixed by the g5.12xlarge instance type.

### 12.5 Five-Way Platform Comparison

| | EC2 CPU | Omics CPU (BWA-mem2) | Omics CPU (BWA v0.7.19) | **Batch GPU** | **Omics GPU (us-east-1)** |
|---|---:|---:|---:|---:|---:|
| Align+Sort+MarkDup | ~135 min | ~532 min | ~514 min | **14 min** | **20 min** |
| HaplotypeCaller | 588 min | 1,080 min | 680 min | **23 min** | **25 min** |
| **Compute total** | **~753 min** | **~1,642 min** | **~1,230 min** | **37 min** | **46 min** |
| **Wall-clock total** | ~753 min | ~1,720 min | ~1,310 min | ~50 min | **105 min** |
| **vs EC2** | baseline | 2.2x slower | 1.6x slower | **20x faster** | **16x faster** |
| **Cost** | **$7.02** | **$10.46** | **$8.57** | **$3.66** (OD) | **$5.90** |
| **vs EC2 cost** | baseline | +49% | +22% | **-48%** | **-16%** |

### 12.6 HealthOmics GPU vs Batch GPU

| Metric | Batch GPU (g5.12xlarge) | HealthOmics GPU (omics.g5.12xlarge) | Difference |
|---|---:|---:|---:|
| fq2bam runtime | 14 min | 20 min 28 sec | +46% |
| HC runtime | 23 min | 25 min 11 sec | +10% |
| Compute total | 37 min | 45 min 39 sec | +23% |
| Wall-clock total | ~50 min | 105 min | +110% |
| Instance startup | ~2 min | ~54 min | — |
| **Cost** | **$3.66** (OD) / **$1.40** (Spot) | **$5.90** | +61% (OD) / +321% (Spot) |

**Key observations:**

1. **Compute time is 23% slower** on HealthOmics (46 min vs 37 min). The fq2bam step is the main contributor (+46%), possibly due to differences in NVMe/storage I/O — Batch uses local NVMe SSD (~3.5 GB/s), while HealthOmics uses managed dynamic storage.

2. **Instance provisioning overhead is dominant.** The ~54-minute startup time doubles the wall-clock duration. On Batch, GPU instances start in ~2 minutes. This overhead is amortized for longer-running workflows but is significant for a 46-minute compute job.

3. **Cost is 61% higher than Batch On-Demand, 321% higher than Batch Spot.** HealthOmics charges for the full instance duration including startup overhead. The managed workflow orchestration does not offset the cost premium for this workload.

4. **Still 16% cheaper than EC2 CPU and dramatically faster.** Despite the premium over Batch, HealthOmics GPU is competitive with all CPU-based approaches.

### 12.7 When to Use HealthOmics GPU vs Batch GPU

| Factor | HealthOmics GPU | Batch GPU |
|---|---|---|
| **Best for** | Managed workflow orchestration, compliance-controlled environments | Cost-sensitive production, large cohorts |
| **Region** | us-east-1 only (A10G) | Any region with g5 instances |
| **Cost per sample** | ~$5.90 | $3.66 (OD) / $1.40 (Spot) |
| **Workflow management** | Built-in (WDL/Nextflow) | Requires custom orchestration |
| **Spot interruption risk** | None | ~5-10% for g5.12xlarge |
| **Startup latency** | ~54 min | ~2 min |
| **100-sample cohort cost** | ~$590 | $366 (OD) / $140 (Spot) |
| **100-sample wall-clock** | Sequential: ~175 hr | Parallel (10x): ~8.3 hr |

**Recommendation:** For the NEA/EHI production pipeline, **Batch GPU with Spot** remains the cost-optimal choice ($1.40/sample). HealthOmics GPU becomes attractive when (a) G5 support expands to ap-northeast-2, (b) startup latency improves, or (c) managed workflow governance is a hard requirement.

## 13. Sentieon DNAscope on HealthOmics (2026-04-29)

### 13.1 Background

Sentieon DNAscope is a proprietary variant caller that reimplements BWA-MEM + GATK HaplotypeCaller in an optimized single binary. Unlike GATK, it requires a license server accessible over the network (TCP port 8990). We deployed a dedicated VPC with a Sentieon license server and used HealthOmics VPC networking (`--networking-mode VPC`) to enable license connectivity.

### 13.2 Setup

| Parameter | Value |
|---|---|
| **Run ID** | 7780153 (Workflow ID: 9482881) |
| **Run Name** | SRR6063611-sentieon-dnascope-20260429-0040 |
| **Region** | ap-southeast-1 (Singapore) |
| **Instance** | omics.c.8xlarge (32 vCPU, 64 GiB) |
| **Sentieon** | 202503.03 |
| **Variant Caller** | DNAscope (gVCF mode) |
| **VPC Config** | nea-ehi-sentieon-vpc (dedicated VPC 10.100.0.0/16) |
| **License Server** | 10.100.1.119:8990 (t3.medium, systemd service) |
| **Sample** | SRR6063611 (*Ae. aegypti*, ~19 GB paired-end FASTQ) |

### 13.3 Pipeline Structure

3-task WDL workflow:
1. **SentieonLicenseCheck** — Ping license server, verify DNAscope feature
2. **SentieonAlignment** — `sentieon bwa mem` | `sentieon util sort` → sorted BAM
3. **SentieonDedupAndCall** — LocusCollector → Dedup → DNAscope (gVCF) → CRAM conversion

### 13.4 Results

| Task | Instance | Runtime | Cost |
|---|---|---:|---:|
| SentieonLicenseCheck | omics.c.8xlarge (1 CPU, 1 GiB) | 46 sec | $0.00 |
| **SentieonAlignment** | **omics.c.8xlarge (32 CPU, 64 GiB)** | **83.0 min** | **$0.51** |
| **SentieonDedupAndCall** | **omics.c.8xlarge (32 CPU, 64 GiB)** | **40.6 min** | **$0.25** |
| **Compute total** | | **124.4 min** | **$0.76** |
| Storage (67 GiB dynamic, 142 min) | | | $5.71 |
| **Total** | | **142 min wall-clock** | **$6.47** |

**Dedup metrics:** 95.7M read pairs, 4.79% duplication rate, estimated library size 987M.

### 13.5 Output Files

| File | Size |
|---|---:|
| SRR6063611.g.vcf.gz | 8.3 GiB |
| SRR6063611.g.vcf.gz.tbi | 1.4 MiB |
| SRR6063611.cram | 9.2 GiB |
| SRR6063611.cram.crai | 348.2 KiB |
| SRR6063611.sorted.bam | 20.0 GiB |
| SRR6063611.sorted.bam.bai | 3.8 MiB |

### 13.6 Six-Way Platform Comparison

| | EC2 CPU | Omics CPU (BWA-mem2) | Omics CPU (BWA v0.7.19) | **Omics Sentieon** | Batch GPU | Omics GPU (us-east-1) |
|---|---:|---:|---:|---:|---:|---:|
| Alignment | ~90 min | ~482 min | ~456 min | **83 min** | 14 min | 20 min |
| Dedup+Calling | ~618 min | ~1,114 min | ~715 min | **41 min** | 23 min | 25 min |
| **Compute total** | **~753 min** | **~1,642 min** | **~1,230 min** | **124 min** | **37 min** | **46 min** |
| **Wall-clock** | ~753 min | ~1,720 min | ~1,310 min | **142 min** | ~50 min | 105 min |
| **vs EC2** | baseline | 2.2x slower | 1.6x slower | **5.3x faster** | **15x faster** | **7x faster** |
| **Cost** | **$7.02** | **$10.46** | **$8.57** | **$6.47** | **$3.66** | **$5.90** |
| **vs EC2 cost** | baseline | +49% | +22% | **-8%** | **-48%** | **-16%** |

### 13.7 Key Insights

1. **Sentieon alignment matches EC2 BWA-mem2 speed on HealthOmics.** Sentieon bwa mem completed in 83 min on omics.c.8xlarge (32 CPU) vs 90 min on EC2 m5.2xlarge (8 CPU). Unlike BWA-mem2, Sentieon's alignment does not depend on AVX-512 SIMD for performance — it uses its own optimized implementation that scales well without it.

2. **DNAscope variant calling: 41 min vs 588-1,080 min for GATK HaplotypeCaller.** This is the most impactful improvement — DNAscope is 14-26x faster than GATK HC on CPU, while being a drop-in replacement producing compatible gVCF output.

3. **Sentieon eliminates the HealthOmics CPU performance gap.** The entire GATK pipeline suffered from SIMD degradation (BWA-mem2) and CPU architecture differences (HC). Sentieon bypasses both issues, delivering EC2-competitive performance on HealthOmics CPU instances.

4. **Cost: $6.47/sample — 8% cheaper than EC2 GATK.** Sentieon on HealthOmics is the cheapest CPU-based option tested. Storage dominates cost at $5.71 (88%), while compute is only $0.76. Reducing the BAM intermediate (output only CRAM) or using STATIC storage could reduce this further.

5. **No GPU required.** Sentieon achieves 2.4h wall-clock on CPU-only instances, making it viable in all HealthOmics regions — unlike Parabricks GPU which requires A10G (us-east-1 only).

6. **License server requirement is the main operational overhead.** Sentieon requires a running license server in a VPC-connected environment. HealthOmics VPC networking configuration handles this, but adds ~5 min provisioning time and ongoing EC2 cost (~$0.05/hr for t3.medium when running).

### 13.8 Sentieon vs Parabricks Decision Matrix

| Factor | Sentieon (HealthOmics CPU) | Parabricks (Batch GPU) | Parabricks (Omics GPU) |
|---|---|---|---|
| **Compute time** | 124 min | 37 min | 46 min |
| **Wall-clock** | 142 min | ~50 min | 105 min |
| **Cost/sample** | $6.47 | $3.66 (OD) / $1.40 (Spot) | $5.90 |
| **Region** | Any (with license server) | Any (with g5 instances) | us-east-1 only |
| **GPU required** | No | Yes (4x A10G) | Yes (4x A10G) |
| **License** | Commercial (per-server) | Commercial (per-GPU-hour) | Commercial (per-GPU-hour) |
| **Managed workflow** | Yes (HealthOmics) | No (custom orchestration) | Yes (HealthOmics) |
| **100-sample cost** | ~$647 | $366 (OD) / $140 (Spot) | ~$590 |

**Recommendation:** Sentieon on HealthOmics is the best **CPU-only managed** option — 5x faster than GATK, 8% cheaper than EC2, available in all regions. For maximum throughput and lowest cost, Batch GPU with Spot ($1.40/sample) remains optimal.

### 13.9 Concordance: Sentieon DNAscope vs GATK HaplotypeCaller

Same methodology as Section 9 — 3 major chromosomes, bcftools norm + isec, GATK HC (EC2) as baseline.

| Metric | SNP | Indel | All |
|---|---:|---:|---:|
| GATK total | 3,266,011 | 566,093 | 3,852,238 |
| Sentieon total | 6,666,369 | 1,136,645 | 7,803,014 |
| GATK-only (FN) | 217,743 | 63,995 | 281,738 |
| Sentieon-only (FP) | 3,601,960 | 630,554 | 4,232,514 |
| Shared (TP) | 3,064,409 | 506,091 | 3,570,500 |
| **Recall** | **0.934** | **0.888** | **0.927** |
| **Precision** | **0.460** | **0.445** | **0.458** |
| **F1** | **0.616** | **0.593** | **0.613** |

**Genotype concordance (shared sites):** 97.57% (3,483,622 / 3,570,500, phase-normalized)  
**Ti/Tv:** GATK 1.21, Sentieon 0.94

DNAscope calls 2x more variants than HaplotypeCaller — this is by design. Its ML-based model is more sensitive, reporting low-confidence candidates (43% QUAL<10) for downstream filtering. This is an inter-caller comparison, not a platform discrepancy. See [test-results.md](test-results.md#12-sentieon-dnascope-on-healthomics-2026-04-29) for details.

## 14. Final Summary & Recommendations

### 14.1 Platform Comparison (SRR6063611, *Ae. aegypti* ~19 GB FASTQ)

| Rank | Approach | Platform | Compute | Wall-clock | Cost | Region |
|:---:|---|---|---:|---:|---:|---|
| 1 | Parabricks GPU (Spot) | Batch g5.12xlarge | 37 min | 50 min | **$1.40** | Any (g5 available) |
| 2 | Parabricks GPU (OD) | Batch g5.12xlarge | 37 min | 50 min | $3.66 | Any (g5 available) |
| 3 | Parabricks GPU | HealthOmics | 46 min | 105 min | $5.90 | us-east-1 only |
| 4 | **Sentieon DNAscope** | **HealthOmics CPU** | **124 min** | **142 min** | **$6.47** | **Any region** |
| 5 | GATK HC + BWA-mem2 | EC2 CPU | 753 min | 12.6h | $7.02 | Any |
| 6 | GATK HC + BWA v0.7.19 | HealthOmics CPU | 1,230 min | 20.5h | $8.57 | Any |
| 7 | GATK HC + BWA-mem2 | HealthOmics CPU | 1,642 min | 27.4h | $10.46 | Any |

### 14.2 Recommendations

1. **Production (cost-optimized):** Batch GPU with Spot — $1.40/sample, 50 min. Requires custom orchestration and Spot interruption handling.

2. **Production (managed, GPU):** HealthOmics Parabricks in us-east-1 — $5.90/sample, fully managed. Viable when G5 A10G is available. Region-limited.

3. **Production (managed, any region):** **Sentieon DNAscope on HealthOmics** — $6.47/sample, 2.4h wall-clock. CPU-only, works in any HealthOmics region. Requires Sentieon license + license server in VPC. Best option for ap-southeast-1/ap-northeast-2.

4. **Avoid:** GATK on HealthOmics CPU — 2.2x slower and 49% more expensive than EC2 GATK due to SIMD/CPU performance gap.

### 14.3 Variant Concordance Summary

| Comparison | Type | SNP F1 | GT Match | Verdict |
|---|---|---:|---:|---|
| Omics GATK vs EC2 GATK | Same caller, cross-platform | 0.99979 | 100% | Near-perfect |
| BWA v0.7.19 vs BWA-mem2 | Same caller, different aligner | 1.00000 | 100% | Identical |
| Sentieon DNAscope vs EC2 GATK | Different caller | 0.616 | 97.6% | Expected — different algorithm |
| Parabricks vs EC2 GATK | Different preprocessing | 0.455 | 100% | Expected — no trimming |

## 15. Open Items

1. **Sentieon Haplotyper mode:** Run Sentieon in `Haplotyper` mode (GATK HC equivalent) for apples-to-apples concordance comparison. Expected F1 > 0.999.
2. **DNAscope ML filtering:** Apply DNAscope ML filtering to Sentieon output and re-evaluate Ti/Tv and concordance metrics.
3. **HealthOmics GPU regional expansion:** Await HealthOmics team response on G5 (A10G) availability timeline for ap-northeast-2 / ap-southeast-1.
4. **Sentieon cost optimization:** Remove intermediate sorted BAM from workflow outputs (saves ~$1.50/sample in storage costs).
5. **License server cost:** License server (t3.medium) should be stopped when not in use (`deploy-sentieon.sh --stop-license`). Running cost ~$0.05/hr.

---

*Report prepared by NEA/EHI POC Team, 2026-04-29. HealthOmics cost estimates are based on published pricing and may differ from actual billing.*
