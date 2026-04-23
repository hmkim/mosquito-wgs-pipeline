# Genomics Pipeline Overview — NEA/EHI POC

Three genomics pipelines for *Aedes aegypti* (yellow fever mosquito) research, based on the pipeline design from the *Nature Communications* 2025 paper: "Dengue virus susceptibility in *Aedes aegypti* linked to natural cytochrome P450 promoter variants" (doi:10.1038/s41467-025-62693-y).

---

## 1. GATK Mosquito WGS Pipeline

**Location:** `workflows/gatk/gatk-mosquito.wdl` + `workflows/gatk/joint-genotyping.wdl`

**Purpose:** Whole-genome variant discovery in *Aedes aegypti* mosquitoes.

**Scale:** 300 samples x 30 batches, 10-15x depth, 5-10 GB FASTQ per sample.

### Per-Sample Pipeline (`gatk-mosquito.wdl`)

| Step | Tool | CPUs | Memory | Output |
|------|------|------|--------|--------|
| 1. QC | FastQC v0.12.1 | 2 | 4 GB | HTML reports per read |
| 2. Trimming | FastP | 4 | 8 GB | Trimmed FASTQ.gz; HTML + JSON report |
| 3. Alignment | BWA-mem2 | 8 | 16 GB | Unsorted BAM |
| 4. Sort & Index | SAMtools sort/index | 4 | 8 GB | Sorted BAM + BAI |
| 5. Deduplication | GATK MarkDuplicates | 2 | 8 GB | Deduplicated BAM + metrics |
| 6. Variant Calling | GATK HaplotypeCaller | 4 | 16 GB | Per-sample gVCF.gz + TBI |

**Key Parameters:**

- FastP: `--qualified_quality_phred 20`, `--length_required 50`
- BWA-mem2: 8 threads, read group platform `ILLUMINA`
- HaplotypeCaller: `-ERC GVCF` mode, `--min-base-quality-score 20`
- MarkDuplicates: `--REMOVE_DUPLICATES false` (marks but retains duplicates)
- Reference genome: AaegL5 (*Aedes aegypti* Level 5 assembly)

### Joint Genotyping Pipeline (`joint-genotyping.wdl`)

| Step | Tool | CPUs | Memory | Disk | Output |
|------|------|------|--------|------|--------|
| 1. Consolidate | GATK GenomicsDBImport | 4 | 32 GB | 500 GB SSD | GenomicsDB workspace |
| 2. Joint Call | GATK GenotypeGVCFs | 4 | 16 GB | - | Raw cohort VCF.gz |
| 3. Filter | BCFtools filter + view + tabix | 2 | 8 GB | - | Filtered VCF.gz + TBI |

### SNP Filtering Criteria (from reference paper)

| Filter | Threshold | Purpose |
|--------|-----------|---------|
| QD | < 5 | Quality by depth — removes low-confidence variants |
| FS | > 60 | Fisher strand bias — removes strand-biased calls |
| ReadPosRankSum | < -8 | Read position bias — removes end-of-read artifacts |
| GQ | > 20 | Genotype quality per sample |
| DP | >= 10 | Minimum read depth per genotype (10x) |

### Container (`workflows/gatk/Dockerfile`)

Base image: `broadinstitute/gatk:4.5.0.0`

Additional tools: BWA-mem2 v2.2.1, FastQC v0.12.1, FastP, BCFtools 1.20, MultiQC v1.22.

---

## 2. RADseq Population Genetics Pipeline

**Location:** `workflows/radseq/main.nf` (Nextflow DSL2)

**Purpose:** Restriction-site-associated DNA sequencing for population-level SNP discovery in *Aedes aegypti*.

**Scale:** 600 samples x 15 batches, SbfI restriction enzyme, UMI barcodes.

### Pipeline Processes

| Process | Tool | CPUs | Memory | Key Parameters |
|---------|------|------|--------|----------------|
| FASTQC | FastQC | 2 | - | `--threads 2` |
| FASTP | FastP | 4 | - | phred 20, length 50 |
| CDHIT_CLUSTER | CD-HIT-est v4.8.1 | 8 | 16 GB | Identity `-c 0.90`, word length `-n 8` |
| RAINBOW_ASSEMBLY | Rainbow v2.0.4 | - | - | `div` / `merge -a` / `build` |
| BWA_INDEX | BWA-mem2 + SAMtools faidx | - | - | Index reference or pseudoreference |
| BWA_ALIGN | BWA-mem2 | 8 | 16 GB | 8 threads, ILLUMINA read group |
| UMI_DEDUP | UMI-tools v1.1.5 | - | - | `umi_tools dedup` with stats |
| SAMTOOLS_MERGE_INDEX | SAMtools | 4 | - | Sort + index |
| BEDTOOLS_INTERVALS | BEDtools | - | - | `bamtobed` / `merge` / `sort` |
| FREEBAYES | FreeBayes v1.3.7 | 4 | 8 GB | min-mapping-quality 20, min-coverage 5 |
| BCFTOOLS_MERGE | BCFtools + tabix | - | - | Index, merge, sort, gzip |
| MULTIQC | MultiQC v1.22 | - | - | Aggregate FastQC + FastP reports |

### De Novo Mode (`params.use_denovo = true`)

When no reference genome is available:

1. Collect all trimmed R1 reads; extract first 1,000,000 reads to FASTA.
2. **CD-HIT-est** clusters at 90% identity to produce `clustered.fasta`.
3. **Rainbow** assembles clusters into `pseudoreference.fasta`.
4. Pseudoreference is used in place of AaegL5 for all downstream steps.

### Execution Profiles (`workflows/radseq/nextflow.config`)

| Profile | Executor | Region | Resource Tiers |
|---------|----------|--------|----------------|
| `healthomics` | awsbatch | ap-southeast-1 | low (2/4GB), medium (4/8GB), high (8/16GB) |
| `local` | local | - | 4 CPU / 8 GB |

### Container (`workflows/radseq/Dockerfile`)

Base image: `ubuntu:22.04`

Compiled from source: SAMtools 1.20, HTSlib 1.20, BCFtools 1.20, BEDtools v2.31.1, CD-HIT v4.8.1, Rainbow v2.0.4. Pre-built binaries: BWA-mem2 v2.2.1, FreeBayes v1.3.7, FastQC v0.12.1, FastP. Pip-installed: UMI-tools v1.1.5, MultiQC v1.22.

---

## 3. Microbial WGS Pipeline

**Purpose:** Mosquito microbiome analysis (endosymbionts and associated pathogens).

**Scale:** 200 samples x 20 batches, **100x depth** (much deeper than mosquito WGS at 12x).

**Target Organisms:** Wolbachia, Serratia, Asaia, Enterobacter.

**Pipeline:** Reuses the GATK WDL workflow (`gatk-mosquito.wdl`) with microbial reference genomes instead of AaegL5.

---

## Infrastructure

### AWS HealthOmics (`infra/lib/genomics-stack.ts`)

| Resource | Name | Description | Encryption |
|----------|------|-------------|------------|
| Reference Store | `nea-ehi-reference-store` | AaegL5 genome (2-3 GB) + microbial references | KMS CMK |
| Sequence Store | `nea-ehi-sequence-store` | Raw FASTQ data for all three pipelines | KMS CMK |

### S3 Bucket Structure

```
nea-ehi-poc-data-{account}/
  reference/
    mosquito/AaegL5/        # AaegL5.fasta + BWA indices
    microbial/               # Microbial reference genomes
  raw/
    mosquito-gatk/           # WGS FASTQ files (300 samples)
    mosquito-radseq/         # RADseq FASTQ files (600 samples)
    microbial/               # Microbial WGS FASTQ (200 samples)
  results/
    gatk/                    # gVCF, VCF, QC reports
    radseq/                  # Per-sample VCF, cohort VCF, MultiQC
```

### Database Schema (`db/migrations/001_initial_schema.sql`)

**`samples` table:** Tracks every sequencing sample.

| Column | Type | Description |
|--------|------|-------------|
| sample_id | UUID (PK) | Auto-generated |
| external_id | VARCHAR(100) | Lab identifier |
| type | VARCHAR(50) | `mosquito-gatk` / `mosquito-radseq` / `microbial` |
| batch | VARCHAR(50) | Batch identifier |
| status | VARCHAR(20) | `pending` / `running` / `completed` / `failed` |
| s3_path | TEXT | S3 prefix for raw FASTQ |
| metadata | JSONB | Collection date, location, read length, depth target, enzyme, UMI flag, organism |

**`pipeline_runs` table:** Tracks each HealthOmics workflow execution.

| Column | Type | Description |
|--------|------|-------------|
| run_id | UUID (PK) | Auto-generated |
| sample_id | UUID (FK) | References `samples.sample_id` |
| pipeline_type | VARCHAR(50) | `gatk-mosquito` / `gatk-microbial` / `radseq` |
| omics_run_id | VARCHAR(100) | AWS HealthOmics native run ID |
| status | VARCHAR(20) | `pending` / `running` / `completed` / `failed` |
| output_path | TEXT | S3 path to pipeline outputs |
| qc_metrics | JSONB | FastQC / MultiQC metrics |

### Seed Data (`db/migrations/002_seed_data.sql`)

- 20 GATK mosquito samples (AE_GATK_001 to AE_GATK_020) from 10 Singapore locations
- 10 RADseq samples (AE_RAD_001 to AE_RAD_010) with SbfI enzyme and UMI barcodes
- 10 Microbial samples (MB_001 to MB_010) covering 4 organisms at 100x depth

---

## Key Design Decisions

### Two Variant Callers for Two Study Designs

| Pipeline | Variant Caller | Rationale |
|----------|---------------|-----------|
| WGS (GATK) | HaplotypeCaller + GenotypeGVCFs | Higher sensitivity; joint calling across cohort for rare variant discovery |
| RADseq | FreeBayes | Suitable for reduced-representation sequencing; interval-restricted calling via BEDtools |

### Two Deduplication Strategies

| Pipeline | Dedup Tool | Method |
|----------|-----------|--------|
| WGS (GATK) | GATK MarkDuplicates | Coordinate-based |
| RADseq | UMI-tools | UMI barcode-based (more accurate for UMI-tagged RADseq libraries) |

### Tool Version Consistency

Both GATK and RADseq containers install identical versions of shared tools to ensure QC metrics comparability:

- SAMtools 1.20
- BCFtools 1.20
- BWA-mem2 v2.2.1
- FastQC v0.12.1
- FastP (latest)
- MultiQC v1.22
