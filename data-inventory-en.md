# Data Inventory — Mosquito WGS Genomics Pipeline

**Date:** 2026-04-14 (updated 2026-04-27)  |  **Region:** ap-northeast-2  |  **Total Size:** ~268 GiB (raw + reference + Parabricks output)

---

## 1. Reference Genome (8.1 GiB)

**Source:** NCBI [GCF_002204515.2](https://www.ncbi.nlm.nih.gov/datasets/genome/GCF_002204515.2/) — AaegL5.0 (*Aedes aegypti*)  
**S3 Prefix:** `reference/mosquito/AaegL5/`

| File | Size | Description |
|------|------|-------------|
| `AaegL5.fasta` | 1.2 GiB | Genome (3 chromosomes + 2,307 scaffolds, 1.279 Gb) |
| `AaegL5.fasta.fai` | 85.6 KiB | samtools faidx index |
| `AaegL5.dict` | 320.2 KiB | GATK sequence dictionary |
| `AaegL5.fasta.0123` | 2.4 GiB | BWA-mem2 index |
| `AaegL5.fasta.amb` | 3.7 KiB | BWA-mem2 index |
| `AaegL5.fasta.ann` | 420.7 KiB | BWA-mem2 index |
| `AaegL5.fasta.bwt.2bit.64` | 3.9 GiB | BWA-mem2 index |
| `AaegL5.fasta.pac` | 304.9 MiB | BWA-mem2 index |
| `AaegL5.gff3` | 117.4 MiB | Gene annotation (NCBI Release 101) |
| `cds_from_genomic.fna` | 67.3 MiB | CDS sequences (28,317) |
| `protein.faa` | 21.4 MiB | Protein sequences (28,317) |
| `rna.fna` | 99.8 MiB | RNA sequences (33,013) |
| `sequence_report.jsonl` | 675.9 KiB | Sequence metadata |

**Reproduction:**

```bash
datasets download genome accession GCF_002204515.2 --include gff3,rna,cds,protein,genome,seq-report
unzip ncbi_dataset.zip
samtools faidx AaegL5.fasta
gatk CreateSequenceDictionary -R AaegL5.fasta
bwa-mem2 index AaegL5.fasta   # Requires ~80 GB RAM
```

---

## 2. Raw FASTQ — WGS Illumina Paired-End (170.3 GiB)

**Source:** NCBI SRA, BioProject [PRJNA318737](https://www.ncbi.nlm.nih.gov/bioproject/PRJNA318737)  
**Organism:** *Aedes aegypti* (strain LVP_AGWG)  
**S3 Prefix:** `raw/mosquito-wgs/`

| SRA Accession | Platform | Read Length | Spots | Raw Bases | Compressed | Est. Coverage |
|---------------|----------|-------------|-------|-----------|------------|---------------|
| SRR6063610 | NextSeq 500 | 150 bp PE | 112M | 33.8 Gb | 21.5 GiB | ~26x |
| SRR6063611 | NextSeq 500 | 150 bp PE | 98M | 29.6 Gb | 18.8 GiB | ~23x |
| SRR6063612 | NextSeq 500 | 150 bp PE | 101M | 30.4 Gb | 19.3 GiB | ~23x |
| SRR6063613 | NextSeq 500 | 150 bp PE | 111M | 33.6 Gb | 21.3 GiB | ~26x |
| SRR6118663 | HiSeq 2500 | ~200 bp PE | 517M | 104.4 Gb | 89.4 GiB | ~80x |

**Naming:** `raw/mosquito-wgs/{SRR}/{SRR}_R1.fastq.gz` and `_R2.fastq.gz`

**Reproduction:**

```bash
# SRA Toolkit v3.1.1
prefetch {SRR} --output-directory ./raw_fastq --max-size 120G
fasterq-dump ./raw_fastq/{SRR}/{SRR}.sra --outdir ./raw_fastq --split-files --threads 8
pigz -p 8 ./raw_fastq/{SRR}_1.fastq && pigz -p 8 ./raw_fastq/{SRR}_2.fastq
```

### Additional Data in BioProject (not downloaded)

| Category | Runs | Total | Platform |
|----------|------|-------|----------|
| WGS PacBio (assembly) | 176 | 315.5 Gb | PacBio RS II |
| WGS Illumina (downloaded above) | 5 | 231.7 Gb | HiSeq 2500 / NextSeq 500 |
| Hi-C (scaffolding) | 2 | 109.8 Gb | HiSeq X Ten |
| 10X Chromium (linked-reads) | 32 | 234.3 Gb | HiSeq 2500 |
| **Total** | **216** | **891.3 Gb** | |

---

## 3. Pipeline Scripts

**S3 Prefix:** `scripts/`

| File | Description |
|------|-------------|
| `01_prepare_reference.sh` | Reference genome indexing (samtools, GATK, BWA-mem2) |
| `02_simulate_reads.sh` | Test data generation with wgsim |
| `03_run_per_sample.sh` | Per-sample: FastQC, FastP, BWA-mem2, MarkDuplicates, HaplotypeCaller |
| `04_joint_genotyping.sh` | GenomicsDBImport, GenotypeGVCFs, variant filtering |
| `05_run_full_test.sh` | End-to-end pipeline test runner |
| `restart_from_bwa.sh` | Restart from BWA alignment step |

---

## 4. Pilot Test Results

**S3 Prefix:** `results/gatk/`

| File | Description |
|------|-------------|
| `test_cohort.raw.vcf.gz` | Raw joint-called VCF (simulated data) |
| `test_cohort.filtered.vcf.gz` | Filtered VCF |
| `test_cohort.filtered.vcf.gz.tbi` | Tabix index |

**Variant Filtering Criteria** (Nature Communications 2025, doi:10.1038/s41467-025-62693-y):

| Filter | Threshold | Purpose |
|--------|-----------|---------|
| QD | < 5 | Quality by depth |
| FS | > 60 | Fisher strand bias |
| ReadPosRankSum | < -8 | Read position bias |
| GQ | > 20 | Genotype quality |
| DP | >= 10 | Minimum read depth |

---

## 5. Parabricks Batch Output (82.4 GiB)

**Date:** 2026-04-26  
**Platform:** AWS Batch, g5.12xlarge (4x A10G)  
**S3 Prefix:** `output/parabricks-batch/SRR6063611/`

| File | Size | Description |
|------|------|-------------|
| `SRR6063611.pb.bam` | 23.6 GiB | Sorted, deduped BAM (Parabricks fq2bam) |
| `SRR6063611.pb.bam.bai` | 3.8 MiB | BAM index |
| `SRR6063611.g.vcf` | 53.2 GiB | Uncompressed gVCF (Parabricks haplotypecaller --gvcf) |

Note: Parabricks outputs uncompressed gVCF by default. The 53.2 GiB file corresponds to ~6.8 GiB compressed (`.g.vcf.gz`).

---

## 6. S3 Directory Structure

```
<BUCKET>/
├── raw/mosquito-wgs/
│   ├── SRR6063610/  (R1: 10.7 GiB, R2: 10.8 GiB)
│   ├── SRR6063611/  (R1:  9.3 GiB, R2:  9.5 GiB)
│   ├── SRR6063612/  (R1:  9.6 GiB, R2:  9.7 GiB)
│   ├── SRR6063613/  (R1: 10.6 GiB, R2: 10.7 GiB)
│   └── SRR6118663/  (R1: 44.3 GiB, R2: 45.1 GiB)
├── reference/mosquito/AaegL5/
│   ├── AaegL5.fasta + .fai + .dict      (genome + indices)
│   ├── AaegL5.fasta.{0123,amb,ann,bwt.2bit.64,pac}  (BWA-mem2)
│   ├── AaegL5.fasta.{bwt,sa}            (BWA v0.7.x)
│   ├── AaegL5.fasta.tar                  (Parabricks ref tarball, 3.3 GiB)
│   ├── AaegL5.gff3                       (annotation)
│   ├── cds_from_genomic.fna, protein.faa, rna.fna
│   └── sequence_report.jsonl
├── results/gatk/
│   └── test_cohort.{raw,filtered}.vcf.gz
├── output/parabricks-batch/
│   └── SRR6063611/                        (BAM + gVCF, 82.4 GiB)
├── omics-output/                          (HealthOmics run outputs)
└── scripts/
    └── 01-05 pipeline scripts
```
