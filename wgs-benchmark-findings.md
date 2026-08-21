# Mosquito WGS Pipeline — Consolidated Benchmark Findings

Single reference document for every measured result, platform finding, correction, and open
limitation from the *Aedes aegypti* WGS benchmark across Amazon EC2, AWS Batch, and AWS HealthOmics.

**Sample:** SRR6063611 (*Aedes aegypti*, NextSeq 500, ~98M read pairs, 2×150 bp, **~23× coverage**)
**Reference:** AaegL5.0 (GCF_002204515.2), 1.279 Gbp
**Tool versions:** Sentieon 202503.03 / sentieon-cli 1.6.2 · GATK 4.5.0.0 · BWA-mem2 2.2.1 · BWA 0.7.19 · Parabricks 4.3.1-1
**Regions:** ap-southeast-1 (Sentieon), ap-northeast-2 (GATK, Parabricks Batch), us-east-1 (Parabricks HealthOmics)
**Measurement basis:** HealthOmics figures reconstructed from `omics get-run` / `omics list-run-tasks`
timestamps; unit prices from the AWS Price List API. Compute rates re-verified 2026-08-21.

> **Sanitisation.** This document deliberately excludes account identifiers, bucket names,
> license-server addresses, ECR registry hosts, personal names, and organisation-identifying
> details. Placeholders follow the repository convention: `<ACCOUNT_ID>`, `<BUCKET>`, `<REGION>`,
> `<LICENSE_SERVER_PRIVATE_IP>`. HealthOmics run IDs are retained as evidence anchors — they are
> scoped to a private account and grant no access on their own.

---

## 1. Performance summary — all measured configurations

Every row is a completed end-to-end run on the same single sample. Costs are recomputed from run
timestamps × API-verified unit rates, not vendor estimates.

| # | Platform | Region | Pipeline | Instance type(s) | Wall-clock | Cost/sample | Run ID |
|---|---|---|---|---|---:|---:|---|
| 1 | **Batch** | ap-southeast-1 | Sentieon DNAscope (CPU) | c7i.8xlarge (32 vCPU, 64 GiB) — one instance, whole pipeline | **97 min** | **$2.67** | — |
| 2 | **HealthOmics** | ap-southeast-1 | **Sentieon WDL v4** (CPU) | omics.c.8xlarge + omics.c.large | **109 min** | **$3.41** | 4976115 |
| 3 | HealthOmics | ap-southeast-1 | Sentieon WDL v2, DYNAMIC | omics.c.8xlarge ×2 + omics.c.large | 119 min | $3.69 | 8615815 |
| 4 | HealthOmics | ap-southeast-1 | Sentieon WDL v3 | omics.c.8xlarge + omics.c.4xlarge + omics.c.large | 162 min | $4.04 | 2266737 |
| 5 | HealthOmics | ap-southeast-1 | Sentieon WDL v3 (rerun) | same as #4 | 162 min | $4.01 | 3637503 |
| 6 | HealthOmics | ap-southeast-1 | Sentieon WDL v2, STATIC | omics.c.8xlarge ×2 + omics.c.large | 123 min | $4.33 | 8692985 |
| 7 | HealthOmics | ap-southeast-1 | Sentieon, slow calling variant | omics.c.8xlarge + omics.c.4xlarge | 222 min | ~$4.3 (est.) | 9105461 |
| 8 | HealthOmics | ap-southeast-1 | Sentieon baseline (v1) | omics.c.8xlarge ×2 + omics.c.large | 142 min | $4.44 | 7780153 |
| 9 | **Batch** | ap-northeast-2 | Parabricks (GPU) | g5.12xlarge (48 vCPU, 4× A10G) — one instance | **44 min** | **$5.12** | — |
| 10 | HealthOmics | us-east-1 | Parabricks (GPU) | omics.g5.12xlarge ×2 tasks | 105 min | $5.90 | 1587591 |
| 11 | **EC2** | ap-northeast-2 | GATK + BWA-mem2 (CPU) | m5.2xlarge (8 vCPU, 32 GiB) — one instance | 12.6 h | $5.93 | — |
| 12 | HealthOmics | ap-northeast-2 | GATK + BWA 0.7.19 | 5 instance types / 6 tasks | 20.6 h | $9.19 | 6503897 |
| 13 | HealthOmics | ap-northeast-2 | GATK + BWA-mem2 | 5 instance types / 6 tasks | 27.4 h | $11.71 | 6185205 |

**Headline results.** Cheapest is Batch with `sentieon-cli` at **$2.67**. Best managed option is
**Sentieon WDL v4 on HealthOmics at $3.41 / 109 min**, which is 15× faster and 71% cheaper than
GATK on the same service, and 7× faster than the GATK EC2 baseline. Fastest overall is Parabricks
on Batch at 44 min, but at nearly double the Sentieon cost and only in GPU-capable regions.

Row 7 (run 9105461) appears in no earlier report. Its cost is an estimate from task durations
(34.1 min alignment on c.8xlarge + 171.3 min DedupAndCall on c.4xlarge = $4.23 compute) because its
storage footprint was not recorded. It looks like an unlogged c.4xlarge calling variant; include it
only with that caveat.

---

## 2. Structural difference in how the two platforms allocate compute

This determines how every cost above should be read.

On **AWS Batch**, the whole pipeline runs as a **single job on one instance**. Every stage has all
vCPUs available and there is exactly one provisioning event.

On **HealthOmics**, each WDL task is scheduled **independently on its own instance, sized to that
task's request**. This is why the GATK runs span five instance types across six tasks, and why every
Sentieon run carries a small `omics.c.large` for the license check.

The trade-off runs both ways:

- **Per-task sizing saves money on light stages.** The four small GATK tasks (FastQC, FastP,
  SortAndIndex, MarkDuplicates) cost $0.39 combined. Batch would bill full 32-vCPU rates for the
  same work.
- **It adds provisioning overhead per task and locks in any undersized request.** That is exactly
  what happened to GATK's HaplotypeCaller (§6).

Our optimisation work confirmed this empirically: **consolidating the Sentieon WDL from two tasks
into one (v4) brought HealthOmics to compute-time parity with Batch — 95 min vs 97 min.** For this
pipeline the cost of splitting outweighed the benefit of right-sizing.

---

## 3. Sentieon DNAscope optimisation, v1 → v4

### 3.1 Version history

| Version | Change | Wall-clock | Cost |
|---|---|---:|---:|
| v1 (baseline) | Original 2-task WDL, no models | 142 min | $4.44 |
| v2 | + BWA model, + DNAscope model & DNAModelApply | 119 min | $3.69 |
| v3 | + native CRAM from Dedup, downsized calling instance | 162 min | $4.02 |
| **v4** | **Single task, all optimisations, NUMA + igzip** | **109 min** | **$3.41** |

v3 is the instructive failure: it applied three legitimate optimisations yet ran **43 min slower and
cost more** than v2. Splitting alignment and calling across differently-sized instances added a
second provisioning cycle and forced the calling stage onto 16 vCPU. v4 discards the split entirely.

### 3.2 Optimisation catalogue

| Optimisation | Source | Effect |
|---|---|---|
| BWA model (`-x` flag) | Sentieon vendor guidance | **Alignment ~2× faster (78 → 33 min)** — the single largest win |
| DNAscope model + DNAModelApply | Sentieon vendor guidance | ML-based variant quality refinement (+5 min) |
| Native CRAM output from Dedup | Sentieon vendor guidance | Peak storage 67 → 60 GiB; avoids a BAM→CRAM pass |
| Remove redundant BAM index | Sentieon vendor guidance | Negligible; the index was unnecessary |
| Downsize calling instance to 16 vCPU | Sentieon vendor guidance | **Counter-productive here** — not used in v4 |
| NUMA-aware BWA parallelisation | Sentieon official WDL | Better memory locality |
| igzip (ISA-L) FASTQ decompression | Sentieon official WDL | Hardware-accelerated input decompression |
| 256 MB pipe buffers | Sentieon official WDL | Fewer I/O stalls between BWA and sort |
| `--bam_compression 1` | Sentieon official WDL | Minimal compression for intermediates |
| Intermediate file deletion | Sentieon official WDL | Lower peak run storage |
| `.so` symlink workaround | This project | Ensures native DNAModelApply — see §4.4 |

### 3.3 v4 versus Batch, stage by stage

| Stage | Batch (c7i.8xlarge, 32t) | HealthOmics v4 (Skylake, 36t) | Note |
|---|---:|---:|---|
| Download / provisioning | 48 s | ~8 min | HealthOmics includes instance startup |
| **BWA alignment + sort** | **27.4 min** | **23.3 min** | igzip + BWA model + 4 extra threads |
| LocusCollector + QC | 1.1 min | 0.8 min | — |
| Dedup (→ CRAM) | 1.2 min | 4.0 min | v4 writes CRAM directly: more CPU, less I/O |
| **DNAscope calling** | **64.5 min** | **61.3 min** | Largest stage |
| **DNAModelApply** | **2.0 min** | **5.3 min** | Batch uses the native `.so` directly |
| GVCFtyper | 0.4 min | — | `sentieon-cli` runs an extra merge |
| Output staging | 1 s | ~2 min | — |
| **Total compute** | **97 min** | **95 min** | Effectively identical |

**The remaining cost gap is structural, not algorithmic.** $3.41 vs $2.67 comes from HealthOmics'
28% higher hourly rate plus ~14 min of provisioning overhead — not from pipeline inefficiency.

### 3.4 Cost breakdown

**Batch, c7i.8xlarge:** 97 min × $1.6464/hr = $2.66 compute + ~$0.01 gp3 EBS = **$2.67**

**HealthOmics v4:**

| Component | Quantity | Rate | Cost |
|---|---|---|---:|
| omics.c.8xlarge compute | 95.1 min | $2.1168/hr | $3.36 |
| omics.c.large (license check) | 21 s, billed at 60 s minimum | $0.1323/hr | $0.002 |
| DYNAMIC run storage | 64 GiB × 1.81 h | $0.0004932/GiB-hr | $0.06 |
| **Total** | | | **$3.42** |

Recomputation gives $3.42 against the $3.41 originally reported — agreement within rounding.

---

## 4. HealthOmics platform findings

These are the findings least likely to be documented elsewhere.

### 4.1 CPU generation is heterogeneous and not user-selectable

HealthOmics does not expose the underlying EC2 instance type, but Sentieon tools log
`/proc/cpuinfo`-equivalent detail at the end of every algorithm. Extracting it from CloudWatch
(`/aws/omics/WorkflowLog`, stream `run/<runId>/task/<taskId>`) shows that **the same `omics.c.*`
instance type is backed by three different CPU generations across runs.**

| CPU model | CPUID | Microarchitecture | Xeon gen | EC2 family | Year |
|---|---|---|---|---|---|
| Xeon Platinum 8124M @ 3.00 GHz | `00050654` | Skylake-SP | 1st Gen Scalable | c5 / m5 / r5 | 2017 |
| Xeon Platinum 8275CL @ 3.00 GHz | `00050657` | Cascade Lake-SP | 2nd Gen Scalable | c5 / m5 refresh | 2019 |
| Xeon Platinum 8375C @ 2.90 GHz | `000606a6` | Ice Lake-SP | 3rd Gen Scalable | c6i / m6i / r6i | 2021 |

Observed per run:

| Run | Alignment task CPU | Calling task CPU |
|---|---|---|
| 8615815 (v2, DYNAMIC) | Skylake 8124M, 36 threads | Skylake 8124M, 36 threads |
| 8692985 (v2, STATIC) | Ice Lake 8375C, 32 threads | Ice Lake 8375C, 32 threads |
| 2266737 (v3) | Skylake 8124M, 36 threads | Skylake 8124M, 16 threads (c.4xlarge) |
| 3637503 (v3 rerun) | Skylake 8124M, 36 threads | **Cascade Lake 8275CL**, 16 threads (c.4xlarge) |
| 4976115 (v4) | Skylake 8124M, 36 threads | (single task) |

All observed instances run Amazon Linux 2023, kernel 6.1.x, and **all support AVX-512** (Cascade
Lake and Ice Lake add VNNI; Ice Lake adds VBMI2, GFNI, VAES).

**Practical consequence.** This introduces roughly 20% run-to-run variance on the dominant stage
with identical inputs, so single-run benchmarks on HealthOmics are not reliable. Quote a range.

### 4.2 Thread count can exceed the requested vCPU count

| Instance (backing CPU) | Requested vCPU | Threads visible | Note |
|---|---:|---:|---|
| omics.c.8xlarge (Skylake 8124M) | 32 | **36** | Backed by c5.9xlarge; 4 extra threads |
| omics.c.8xlarge (Ice Lake 8375C) | 32 | 32 | Exact |
| omics.c.4xlarge (Skylake 8124M) | 16 | 16 | Exact |
| omics.c.4xlarge (Cascade Lake 8275CL) | 16 | 16 | Exact |

When Skylake backs the request, all 36 threads are visible inside the container and Sentieon
auto-detects and uses them. Combined with the higher 3.0 GHz clock, this is the secondary factor
behind the 33 vs 41 min alignment difference between runs 8615815 and 8692985 — both of which used
the BWA model. The **primary** factor is the BWA model itself, not the hardware: runs without it
took 78–83 min *on the same Skylake 36-thread allocation*.

### 4.3 Billed vCPU differs from threads observed

`omics.c.large` logs a single thread but bills as **2 vCPU at $0.1323/hr**, confirmed both against
the Price List API and against the GATK FastQC line item (18.1 min → $0.04). The whole `omics.c`
family prices linearly at **$0.06615 per vCPU-hour** in ap-southeast-1, so instance choice within
the family is cost-neutral per vCPU-hour and should be driven purely by task parallelism.

### 4.4 miniwdl input localisation breaks co-located model files

HealthOmics runs miniwdl, which downloads **each WDL `File` input into its own separate directory**.
Sentieon's DNAModelApply requires its native shared library (`dnascope.model-x86_64.so`) to sit
*adjacent to* the model file. Passing both as WDL inputs therefore silently breaks native execution
and falls back to a Python implementation: **37 min instead of 5.3 min, a 7× penalty.**

Workaround — resolve both real paths and symlink the library next to the model at task start:

```bash
MODEL_PATH=$(realpath "$dnascope_model")
MODEL_DIR=$(dirname "$MODEL_PATH")
SO_PATH=$(realpath "$dnascope_model_so")
ln -s "$SO_PATH" "$MODEL_DIR/$(basename "$SO_PATH")"
```

Confirmed working: the task log shows the symlink being created under `/mnt/workflow/download/...`
and DNAModelApply completing in 5.3 min. The `realpath` guard matters — miniwdl paths may themselves
be symlinks. This pattern generalises to **any tool expecting co-located auxiliary files** on
HealthOmics, not just Sentieon.

### 4.5 Run storage tiers and the DYNAMIC/STATIC breakeven

API-verified rates, ap-southeast-1, 2026-08-21:

| Tier | Rate | Minimum |
|---|---|---|
| STATIC run storage | $0.0002301 / GiB-hr | **1,200 GiB** |
| DYNAMIC run storage | $0.0004932 / GiB-hr | none |
| Ephemeral storage | $0.000133 / GiB-hr | none |

STATIC has the lower unit rate but a 1,200 GiB floor, so **DYNAMIC is cheaper for any pipeline whose
peak footprint is under 560 GiB** (breakeven: 0.0004932 × X = 0.0002301 × 1200 → X = 560 GiB).

Sentieon DNAscope peaks at 64 GiB, far under the breakeven, and the measured runs confirm it:
**DYNAMIC $0.06 versus STATIC $0.57** for the same workload — a 9.5× difference on the storage line,
which is the entire gap between run 8615815 ($3.69) and run 8692985 ($4.33).

**Untested opportunity:** the Ephemeral tier is 3.7× cheaper per GiB-hr than DYNAMIC and appears in
no earlier report. Its applicability to this pipeline has not been evaluated.

---

## 5. Variant-calling agreement: Sentieon versus GATK

Two agreement figures circulate and they look contradictory. Both are correct — they measure
different things, and quoting either alone is misleading.

| Metric | Value | What it measures |
|---|---|---|
| Shared-site genotype concordance | **100%** | Agreement where both callers emit a variant |
| Recall vs GATK | **93.4%** | Fraction of GATK calls Sentieon also makes |
| F1 | **0.616** | Penalises the ~2× additional variants DNAscope emits *by design* |

DNAscope's ML-refined model deliberately calls roughly twice as many variants as GATK
HaplotypeCaller. F1 treats every extra call as a false positive, which is why it looks poor while
genotype concordance at shared sites is perfect. **Always present the pair together.**

### 5.1 The Batch and HealthOmics runs did not emit the same artifact

Verified 2026-08-21 by inspecting the surviving S3 outputs directly. **The two platforms' outputs are
different file types, despite both runs being described as the same pipeline.**

| Run | Artifact in S3 | Size | Evidence |
|---|---|---:|---|
| HealthOmics v4 (4976115) | Full gVCF + CRAM | 10.6 GiB + 9.0 GiB | — |
| Batch (`sentieon-cli`) | **Variant-only VCF**, no CRAM | 203 MiB | see below |

The Batch file is named `SRR6063611.g.vcf.gz` and `batch-run.sh` passes `-g`, but the file is not a
gVCF:

- No `##ALT=<ID=NON_REF>` declaration and no `##GVCFBlock*` header lines.
- Its first data record is at position 8,646 and is a called variant with full annotations
  (`AC`, `AF`, `FS`, `MQ`, `BaseQRankSum`), not a reference block.
- A true Sentieon gVCF from this project starts at position 1 with `<NON_REF>` ALT and `END=` INFO.
- 4,442,751 records genome-wide across the same 2,310 contigs.

The Batch CRAM was also never uploaded — `batch-run.sh` guards each upload with `[ -f "$f" ]`, which
silently skips missing files, so the run's alignment output was lost when the instance terminated.

**What this does and does not change.** It does **not** invalidate the runtime measurements: v4's
DNAscope stage was actually faster (61.3 min vs 64.5 min) while writing far more output. It does mean
**"$2.67 on Batch versus $3.41 on HealthOmics" is not a like-for-like comparison of delivered
artifacts** — the cheaper run produced a variant-only VCF and no alignment file. Anyone quoting the
$2.67 figure should either confirm the Batch configuration emits a full gVCF or state that it does not.

A same-region variant count (`NC_035107.1:1-2,000,000`) gives 2,564 sites for Batch, 16,478 for a
Sentieon gVCF from an earlier HealthOmics run, and 3,729 for GATK on EC2. **This does not establish a
concordance problem** — it compares raw gVCF records against a filtered variant set, which is not a
valid comparison — but it does mean the callers' agreement across platforms is unverified.

**Related finding — Parabricks trimming bias.** Parabricks `fq2bam` performs no adapter trimming.
Without a FastP pre-processing step it produces **9.6M false-positive variants (Ti/Tv 0.43)**, while
shared-site genotype concordance stays at 100%. Trimming is not optional for this data.

---

## 6. GATK on HealthOmics versus EC2 — and a correction to the stated root cause

Identical pipeline both sides: FastQC → FastP → BWA → sort → MarkDuplicates → HaplotypeCaller.
HealthOmics values come from the run 6185205 task record; EC2 stage times were recorded as
approximations during that test and are marked `~`.

| Task | EC2 m5.2xlarge (8 vCPU) | HealthOmics instance | vCPU | HealthOmics time | Cost |
|---|---:|---|---:|---:|---:|
| FastQC | ~15 min | omics.c.large | 2 | 18.1 min | $0.04 |
| FastP | ~15 min | omics.c.xlarge | 4 | 11.6 min | $0.05 |
| **BwaAlign** | ~90 min | omics.m.2xlarge | 8 | **482.0 min** | $4.70 |
| SortAndIndex | ~15 min | omics.m.xlarge | 4 | 15.7 min | $0.08 |
| MarkDuplicates | ~30 min | omics.r.xlarge | 2 | 33.7 min | $0.22 |
| **HaplotypeCaller** | ~588 min | omics.m.xlarge | 4 | **1,080.2 min** | $5.27 |
| Run storage | — | DYNAMIC, 111 GiB × 27.4 h | — | — | $1.38 |
| **Total** | **12.6 h / $5.93** | | | **27.4 h** | **$11.71** |

Two distinct effects explain the gap, and conflating them has led to a wrong conclusion:

**BwaAlign — a genuine platform limitation.** 482 min versus ~90 min **at the same 8 vCPU** is a
5.4× penalty, caused by BWA-mem2 falling back from AVX-512 to SSE4.x in that environment.
Substituting BWA 0.7.19 cut the total to 20.6 h / $9.19 but did not close the gap.

**HaplotypeCaller — a resource sizing issue, not a platform one.** This task ran on **4 vCPU** on
HealthOmics against **8 vCPU** on EC2. Being 1.84× slower on half the CPUs is close to linear
scaling, so it is *not* evidence of a HealthOmics deficit. Earlier reports and correspondence
attributed the whole slowdown to SIMD fallback; the task table does not support that for this stage.

**Why this matters:** HaplotypeCaller alone is $5.27 of the $11.71. **$11.71 is therefore not the
floor for GATK on HealthOmics — it is the cost of an unoptimised resource request.** Raising that
task's `cpu` value is an untested but cheap optimisation. Presenting $11.71 as GATK's best possible
result overstates the case for migrating away from GATK.

*This is a reasoned inference from the task record, not a measured result. One test run would settle it.*

---

## 7. Scaling to multiple samples — method and worked example

No multi-sample run has ever been executed. The following is the defensible way to project one,
using **N = 24** as a worked example.

| Metric | Formula | N = 24 |
|---|---|---|
| Sentieon on HealthOmics | N × $3.41 | **~$82** |
| Sentieon on Batch | N × $2.67 | ~$64 |
| GATK on HealthOmics | N × $11.71 | ~$281 |
| Compute consumed | N × 1.585 instance-h × 32 vCPU | 38 instance-h ≈ **1,217 vCPU-h** |
| Wall-clock, fully parallel | one run's wall-clock | **~1.8 h** |
| Wall-clock, sequential | N × 1.82 h | ~43.6 h |
| Peak run storage, fully parallel | N × 64 GiB, billed per run | 1,536 GiB (DYNAMIC) |

**Quotas are not a constraint at this scale.** The account limit in ap-southeast-1 is 50 concurrent
DYNAMIC-storage runs and 100,000 total runs, so 24 parallel runs need no increase. `StartRun` is
capped at 5 TPS, which is irrelevant here.

**Three things any such projection must state plainly:**

1. **It extrapolates from n = 1.** Per-sample cost is well characterised for one genome; between-sample
   variance is unmeasured.
2. **It excludes joint genotyping.** A multi-sample cohort normally requires joint calling
   (GenomicsDBImport → GenotypeGVCFs). `workflows/gatk/joint-genotyping.wdl` exists but has never
   been run. Its cost does **not** scale per-sample, so a per-sample-only quote is incomplete.
3. **It carries a ±20% band on the dominant stage** because of the CPU heterogeneity in §4.1. Do not
   quote to the cent.

Per-sample cost scales with genome size, so figures measured on a 1.279 Gbp mosquito genome do not
transfer to microbial or reduced-representation (RADseq) data. Any estimate for those is a guess
until measured.

---

## 8. Verified rate card

`omics.c` family and run storage re-verified against the Price List API on **2026-08-21**
(ap-southeast-1, effective 2026-07-01). EC2 rates carry forward from the 2026-07-31 verification.

| Resource | Region | Rate |
|---|---|---|
| omics.c.large (2 vCPU) | ap-southeast-1 | $0.1323 / hr |
| omics.c.xlarge | ap-southeast-1 | $0.2646 / hr |
| omics.c.2xlarge | ap-southeast-1 | $0.5292 / hr |
| omics.c.4xlarge | ap-southeast-1 | $1.0584 / hr |
| omics.c.8xlarge | ap-southeast-1 | $2.1168 / hr |
| omics.c.12xlarge | ap-southeast-1 | $3.1752 / hr |
| omics.c.16xlarge | ap-southeast-1 | $4.2336 / hr |
| omics.c.24xlarge | ap-southeast-1 | $6.3504 / hr |
| DYNAMIC run storage | ap-southeast-1 | $0.0004932 / GiB-hr |
| STATIC run storage | ap-southeast-1 | $0.0002301 / GiB-hr (min 1,200 GiB) |
| Ephemeral storage | ap-southeast-1 | $0.000133 / GiB-hr |
| c7i.8xlarge On-Demand | ap-southeast-1 | $1.6464 / hr |
| m5.2xlarge On-Demand | ap-northeast-2 | $0.4720 / hr |
| g5.12xlarge On-Demand | ap-northeast-2 | $6.9744 / hr |

The `omics.c` family is linear at **$0.06615 / vCPU-hr**. `omics.m` in ap-northeast-2 works out to
$0.2925/hr for m.xlarge and $0.585/hr for m.2xlarge, derived from the run 6185205 line items.
HealthOmics DYNAMIC storage in ap-northeast-2 derives to ~$0.0004535/GiB-hr from the same run —
lower than ap-southeast-1, so **do not reuse storage rates across regions.**

---

## 9. Corrections to superseded figures

Earlier drafts and correspondence contain figures that are wrong or since improved. Use the right
column.

| Claim in circulation | Correct value | Cause of the error |
|---|---|---|
| Sentieon on HealthOmics costs **$6.47**/sample (run 7780153) | **$4.44** for that run; **$3.41** current best | Storage line computed as $5.71 instead of $0.08 — wrong by ~73× |
| EC2 GATK baseline **$7.02** | **$5.93** | Used $0.4960/hr and added EBS; API rate is $0.4720/hr |
| Parabricks on Batch: **37 min/$3.66** or **50 min/$1.40** (Spot) | **44 min / $5.12** | Only self-consistent pair: 44 min × $6.9744/hr = $5.11 |
| Best managed result is **$3.69** (v2) or **$4.02** (v3) | **$3.41** (v4) | Predates the v4 single-task rewrite |
| `omics.c.large` at **$0.0330/hr** | **$0.1323/hr** | API-confirmed; affects the rate card, not the totals |
| Batch `c7i.8xlarge` CPU is **8375C @ 2.90 GHz (Ice Lake)** | **8488C, Sapphire Rapids** (inferred from instance family, not logged) | Copy-paste from a HealthOmics Ice Lake run |
| Sample coverage **~15×** | **~23×** | 98M pairs × 2 × 150 bp ÷ 1.279 Gbp = 23.0×. 15× implies ~98 bp reads, which matches no NextSeq 500 kit |
| 33-min alignment is an **anomaly / outlier** | It is the **expected** result with the BWA model | Misattributed before the BWA model's effect was isolated |

---

## 10. Known limitations and open items

Stated plainly so no downstream reader over-reads the numbers.

**Limitations of the current evidence**

1. **All 13 runs (12 distinct configurations) used the same single sample.** This is a platform and pipeline benchmark,
   not a cohort study. Between-sample variance is unmeasured. The only repeated measurement is the
   v3 reproducibility pair (162 min both times, $4.04 / $4.01).
2. **Joint genotyping is entirely unbenchmarked.** The WDL exists and has never been run.
3. **EC2 and Batch results are no longer independently re-verifiable.** The Sentieon Batch job
   queues no longer exist in the account, and EC2 stage timings were recorded as approximations
   (`~15 min`, `~135 min`). HealthOmics figures are fully reconstructable from the API; EC2 and Batch
   figures rest on the reports alone.
4. **The HaplotypeCaller under-provisioning conclusion (§6) is inferred, not measured.**
5. **Only one aligner comparison exists per platform,** and only on this one genome.
6. **The Batch and HealthOmics runs emitted different artifact types** (§5.1), so the cheapest and
   best-managed figures are not a like-for-like output comparison.

**Open items, in rough priority order**

1. Resolve the Batch output-type discrepancy (§5.1) before quoting $2.67 as the cheapest route:
   confirm the correct `sentieon-cli` gVCF flag, fix the silent `[ -f "$f" ]` upload guard in
   `batch-run.sh` so missing outputs fail loudly, and re-run if a full gVCF is required.
2. Re-run GATK on HealthOmics with a larger `cpu` request for HaplotypeCaller — cheap, and it
   determines whether $11.71 or something materially lower is the real GATK figure.
3. Benchmark joint genotyping so a cohort cost can be quoted at all.
4. Run ≥3 samples on Sentieon v4 to establish a between-sample variance band.
5. Evaluate the Ephemeral storage tier (§4.5).
6. Confirm the Batch `c7i.8xlarge` CPU model from logs rather than inference.
7. Measure microbial and RADseq per-sample cost instead of extrapolating from genome size.

**Operational constraint**

The Sentieon POC license expired **2026-05-31**. Every sub-$4 result in this document depends on
Sentieon, so none of them can be reproduced today without a renewed or commercial license. GATK
requires no license but costs ~$11.71/sample and 20–27 h per sample on HealthOmics.

---

## 11. Recommendations

| Priority | Choice | Rationale |
|---|---|---|
| Lowest cost | Batch + `sentieon-cli`, $2.67 | 22% cheaper than managed, but **its surviving output is a variant-only VCF with no CRAM** (§5.1) — confirm the emitted artifact before relying on this figure. Also requires operating a compute environment (CE, job queue, job definition, launch template) |
| Best managed | **Sentieon WDL v4 on HealthOmics, $3.41 / 109 min** | Compute-time parity with Batch, no infrastructure to run, works in ap-southeast-1, DYNAMIC per-run storage billing |
| Lowest wall-clock | Parabricks on Batch, 44 min / $5.12 | GPU regions only; **requires FastP pre-processing** (§5) |
| GATK continuity | GATK on HealthOmics | Supported, but re-run with corrected HaplotypeCaller sizing before using $11.71 for any planning |

For a 1.279 Gbp genome in a region without HealthOmics GPU support, **Sentieon DNAscope v4 on
HealthOmics is the recommended managed path**, with Batch as the cost-optimised alternative when
infrastructure management is acceptable.
