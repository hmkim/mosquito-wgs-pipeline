# Pipeline Analysis — Crawford et al. 2024 vs NEA-EHI Pipeline

**Date:** 2026-04-23
**Paper:** Crawford et al. (2024) "Sequencing 1206 genomes reveals origin and movement of *Aedes aegypti* driving increased dengue risk" (bioRxiv, doi:10.1101/2024.07.23.604830)
**Scope:** Comparison of the paper's bioinformatics workflow with our NEA-EHI WGS pipeline, with recommendations

---

## 1. Crawford et al. 2024 — Complete Analysis Workflow

### 1.1 Short-Read Mapping

| Step | Tool | Version | Parameters |
|---|---|---|---|
| Alignment | **BWA mem** | **v0.7.16** | **default parameters** |
| Sort | samtools sort | 1.1 | — |
| Mark Duplicates | Picard MarkDuplicates | 2.1.0 | — |
| Indel Realignment | GATK IndelRealigner | v3.8-1-0-gf15c1c3ef | default |
| Read Clipping | clipOverlap (bamUtil) | 1.0.14 | — |

Reference: *Ae. aegypti* L5 genome (NCBI WGS Project NIGP01; same assembly as GCF_002204515.2).

### 1.2 Iterative Reference Updating

Crawford et al. performed a subspecies-specific iterative reference updating process to reduce reference bias. The steps are:

**For *Ae. aegypti formosus* (Aaf, African subspecies):**
1. Map all Aaf reads to AaegL5 reference using BWA mem
2. Call consensus from the pileup (majority allele at each position)
3. Replace reference bases with consensus alleles to create an *Aaf-updated reference*
4. Re-map all Aaf reads to this updated reference
5. Repeat the update-and-remap cycle (described in Rose et al. 2020)

**For *Ae. aegypti aegypti* (Aaa, non-African subspecies):**
1. Select 100 random Aaa males
2. Align to the L5 AaegL5 reference
3. Update reference with consensus alleles from the pileup
4. **Repeat 3 times** (3 iterations of consensus → remap)
5. Use the final updated reference for all Aaa samples

**Observed improvements per iteration (from Rose et al. 2020, Figure S5):**
- Number of reads mapping: increased
- Number of sites covered: increased
- Number of heterozygous sites discovered: increased
- Mismatches between reads and reference: decreased

**Why they do this:** AaegL5 is derived from the LVP_AGWG inbred laboratory strain, which is of Aaa origin. African Aaf populations diverge by ~3-5% from this reference. Without reference updating, Aaf reads with many mismatches may fail to map or map with low quality, causing reference bias in variant calling.

### 1.3 Post-Alignment Processing

| Step | Tool | Details |
|---|---|---|
| Indel Realignment | GATK 3.8 IndelRealigner | Per-population, default settings |
| Overlap Clipping | bamUtil clipOverlap | v1.0.14 — removes overlapping bases in PE reads |

### 1.4 Variant Calling

| Step | Tool | Parameters |
|---|---|---|
| **SNP Calling** | **ANGSD** (likelihood ratio test) | p-value threshold **1e-6** |
| VCF generation | samtools mpileup + BCFtools | `-q 10 -Q 20 -l -u -t SP,DP` |
| SNP filtering | BCFtools + SNPcleaner (ngsQC) | `-f GQ -c` flags |
| Site filtering | SNPcleaner.pl | MIN_IND, MAXD thresholds per population |
| Depth filtering | Custom | Exclude sites >50% above local max depth |

Called separately for Aaf (n=425) and Aaa (n=778), then merged:
- 120.68 million variant sites in Aaf
- 66.02 million variant sites in Aaa
- **141.42 million unique variants** total (union)
- **1,138,636,693 robust sites** after all filters

### 1.5 Downstream Population Genomics

| Analysis | Tool | Notes |
|---|---|---|
| LD pruning | PLINK | 100-variant windows, LD cutoff 0.1 |
| Phasing | HAPCUT2 → SHAPEIT4 v4.2 | Read-based pre-phasing, then statistical |
| Admixture | NGSadmix (ANGSD) | K=2 to K=14, 20 replicates each |
| PCA | PCAngsd v0.982 | Covariance matrix, -minMaf 0.01 |
| Genetic distance | realSFS → 2D SFS (ANGSD) | D_xy pairwise |
| Relatedness | NgsRelate | KING-robust and R1 statistics |
| Coalescent | MSMC2 + MSMC-IM | Effective population size + migration |
| Selection scans | PBS (Population Branch Statistic) | NGSadmix allele frequencies |
| Inversions | Lostruct (windowed PCA) | 0.5 MB non-overlapping windows |

---

## 2. Comparison with NEA-EHI Pipeline

### 2.1 Core Alignment & Preprocessing

| Component | Crawford et al. 2024 | NEA-EHI (current) | Assessment |
|---|---|---|---|
| Aligner | BWA mem v0.7.16 | BWA-mem2 v2.2.1 (+ BWA v0.7.18) | BWA variant now matches |
| Alignment params | default | default | **Matches** |
| Reference | AaegL5 (NIGP01) | AaegL5 (GCF_002204515.2) | **Same assembly** |
| Trimming | None mentioned | FastP (Q20, min 50bp) | Our approach is more conservative |
| Sort | samtools 1.1 | samtools 1.20 | Compatible (newer version) |
| Mark Duplicates | Picard 2.1.0 | GATK 4.5 MarkDuplicates | **Same tool** (Picard integrated into GATK4) |
| Indel Realignment | GATK 3.8 IndelRealigner | Not needed (GATK4 HC handles internally) | **Correct for GATK4** |
| Overlap Clipping | bamUtil clipOverlap | Not included | See note below |
| Ref Updating | Yes (iterative, 3 rounds) | Not included | See Section 3 |

**Note on Overlap Clipping:** Crawford et al. clip overlapping bases in paired-end reads to avoid double-counting in low-depth (~11x) data. GATK 4.x HaplotypeCaller handles overlapping read pairs internally (via `--dont-use-soft-clipped-bases` and its local reassembly), making explicit clipping less critical for GATK-based pipelines.

### 2.2 Variant Calling Strategy

| Aspect | Crawford et al. | NEA-EHI | Reason for Difference |
|---|---|---|---|
| Method | **ANGSD** (genotype likelihoods) | **GATK HaplotypeCaller** (hard calling) | Different study designs |
| Sample depth | ~11x average (low-depth) | 23-26x (medium-depth) | Our data supports hard calling |
| Scale | 1,206 samples simultaneously | Per-sample gVCF → joint genotyping | Incremental sample addition |
| Approach | Population-level allele frequencies | Individual genotype calls | Public health vs. pop genomics |

**Why the difference is appropriate:**

Crawford et al.'s ANGSD approach works with genotype *likelihoods* rather than hard genotype calls, which is optimal for low-depth (~11x) data from 1,200+ samples. It avoids the information loss of forcing diploid calls at low coverage.

Our GATK HaplotypeCaller approach produces individual-level genotype calls, which is appropriate because:
- Our samples are 23-26x depth — sufficient for confident diploid genotyping
- gVCF format allows incremental addition of future samples without reprocessing
- GATK joint genotyping is the established standard for clinical/public health genomics
- Per-sample gVCFs enable sample-level QC and re-analysis

### 2.3 SNP Filtering

| Filter | Crawford et al. | NEA-EHI (from Merkling et al. 2025) |
|---|---|---|
| QD | — | < 5 |
| FS | — | > 60 |
| ReadPosRankSum | — | < -8 |
| GQ | — | > 20 |
| DP | — | >= 10 |
| Population-level | MIN_IND, MAXD, depth-based exclusion | — |

Crawford et al. use population-specific filtering thresholds (MIN_IND = 12 for large populations, sample-size-scaled MAXD). Our per-sample GATK filters (from Merkling et al. 2025 Nature Communications) are a different but well-established approach suitable for joint genotyping.

---

## 3. Iterative Reference Updating — Analysis and Recommendations

### 3.1 What It Does

Iterative reference updating replaces the standard AaegL5 reference bases with consensus alleles from the study population. This creates a "closer" reference that:
- **Increases mapping rate** — fewer mismatches means more reads pass the mapping quality threshold
- **Increases callable sites** — particularly in divergent genomic regions
- **Reduces reference bias** — the reference allele is no longer systematically favored in heterozygous calls

### 3.2 When It Matters Most

| Scenario | Reference Bias Risk | Updating Needed? |
|---|---|---|
| Same strain as reference (LVP_AGWG) | Very low | **No** |
| Same subspecies (Aaa) | Low (~1-2% divergence) | Optional |
| Different subspecies (Aaf, African) | **High (~3-5% divergence)** | **Yes** |
| Wild Aaa from diverse geographic origins | Low-moderate | Recommended for pop gen |
| NEA samples (Singapore, likely Aaa) | Low | **No (for initial analysis)** |

### 3.3 Relevance to Our Project

**Current samples (PRJNA318737, LVP_AGWG strain):** These are from the same inbred laboratory strain used to build the AaegL5 reference. Reference bias is minimal — **iterative reference updating is not needed**.

**Future NEA field samples (Singapore *Ae. aegypti*):** Singapore mosquitoes are Aaa (non-African subspecies), closely related to the reference. Reference updating would provide marginal improvement. It is **recommended for large-scale population genomics** but **not required for initial variant calling**.

**If African Aaf samples are ever analyzed:** Reference updating becomes important and should be implemented.

### 3.4 Implementation Plan (if needed in future)

```
Round 1:
  1. Align all samples → AaegL5 (standard BWA mem)
  2. Call consensus per-site (samtools mpileup → majority allele)
  3. Replace reference bases → AaegL5_updated_v1

Round 2:
  4. Re-align all samples → AaegL5_updated_v1
  5. Call consensus again
  6. Replace reference bases → AaegL5_updated_v2

Round 3:
  7. Re-align all samples → AaegL5_updated_v2
  8. Call consensus again
  9. Replace reference bases → AaegL5_updated_v3 (final)

Final:
  10. Re-align all samples → AaegL5_updated_v3
  11. Proceed with MarkDup → HaplotypeCaller
```

Tools needed: `samtools mpileup`, `bcftools consensus`, `bwa index` (per round). Each round requires full re-alignment of all samples — for 5 samples at ~90 min alignment each, this adds ~4.5 hours per round (13.5 hours total for 3 rounds). At scale (300 samples), consider parallelizing with AWS Batch.

---

## 4. Summary of Differences and Alignment

| Aspect | Status | Action Needed |
|---|---|---|
| Aligner (BWA v0.7.x) | **Now aligned** (gatk-bwa variant) | Test with HealthOmics |
| Reference genome | **Aligned** (same AaegL5) | None |
| Trimming | Our pipeline adds FastP | None — more conservative is fine |
| MarkDuplicates | **Aligned** (same tool) | None |
| Indel Realignment | Not needed in GATK4 | None |
| Overlap Clipping | Not included | Not needed for GATK4 HC |
| Reference Updating | Not included | Not needed for current samples (LVP_AGWG) |
| Variant Calling | Different (GATK vs ANGSD) | Intentional — different study design |
| SNP Filtering | Different criteria | Both are well-established approaches |

**Overall assessment:** Our pipeline is well-aligned with the field standard for medium-depth GATK-based variant calling. The key differences (GATK vs ANGSD, no reference updating) are appropriate for our study design and sample characteristics. The addition of BWA v0.7.x as an aligner option directly matches the paper's methodology.

---

## References

- Crawford et al. (2024) bioRxiv, doi:10.1101/2024.07.23.604830 — Aaeg1200 genomes
- Rose et al. (2020) *Curr. Biol.* 30, 3570-3579.e6 — Iterative reference updating methodology
- Merkling et al. (2025) *Nature Communications*, doi:10.1038/s41467-025-62693-y — SNP filtering criteria
- Matthews et al. (2018) *Nature* 563, 501-507 — AaegL5 reference genome
- Li (2013) *arXiv* — BWA-MEM algorithm
