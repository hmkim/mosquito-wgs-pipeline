# Data Inventory — NEA-EHI Mosquito WGS Project

**Date:** 2026-04-14
**S3 Bucket:** `<BUCKET>`
**Region:** ap-northeast-2
**Total Size:** 178.4 GiB (32 objects)

---

## 1. Reference Genome

**Source:** NCBI Genome Assembly GCF_002204515.2
**Assembly:** AaegL5.0 (*Aedes aegypti*, strain LVP_AGWG)
**S3 Prefix:** `s3://<BUCKET>/reference/mosquito/AaegL5/`

| File | Size | Description |
|------|------|-------------|
| `AaegL5.fasta` | 1.2 GiB | Genome sequence (3 chromosomes + 2,307 scaffolds, total 1.279 Gb) |
| `AaegL5.fasta.fai` | 85.6 KiB | samtools faidx index |
| `AaegL5.dict` | 320.2 KiB | GATK sequence dictionary |
| `AaegL5.fasta.0123` | 2.4 GiB | BWA-mem2 index |
| `AaegL5.fasta.amb` | 3.7 KiB | BWA-mem2 index |
| `AaegL5.fasta.ann` | 420.7 KiB | BWA-mem2 index |
| `AaegL5.fasta.bwt.2bit.64` | 3.9 GiB | BWA-mem2 index |
| `AaegL5.fasta.pac` | 304.9 MiB | BWA-mem2 index |
| `AaegL5.gff3` | 117.4 MiB | Gene annotation (NCBI Annotation Release 101) |
| `cds_from_genomic.fna` | 67.3 MiB | CDS sequences (28,317) |
| `protein.faa` | 21.4 MiB | Protein sequences (28,317) |
| `rna.fna` | 99.8 MiB | RNA sequences (33,013) |
| `sequence_report.jsonl` | 675.9 KiB | Sequence metadata report |

**Subtotal:** 8.1 GiB

### Download Method

```bash
# NCBI datasets CLI v18.23.0
datasets download genome accession GCF_002204515.2 \
  --include gff3,rna,cds,protein,genome,seq-report
unzip ncbi_dataset.zip
```

### BWA-mem2 Index (pre-built, already in bucket)

```bash
# Generated on a separate EC2 instance
bwa-mem2 index AaegL5.fasta
samtools faidx AaegL5.fasta
gatk CreateSequenceDictionary -R AaegL5.fasta
```

---

## 2. Raw FASTQ — WGS Illumina Paired-End Reads

**Source:** NCBI SRA, BioProject [PRJNA318737](https://www.ncbi.nlm.nih.gov/bioproject/PRJNA318737)
**Organism:** *Aedes aegypti* (strain LVP_AGWG — same strain as AaegL5 reference)
**S3 Prefix:** `s3://<BUCKET>/raw/mosquito-wgs/`

| SRA Accession | Platform | Read Length | Spots | Raw Bases | Compressed (R1+R2) | Est. Coverage | BioSample |
|---------------|----------|-------------|-------|-----------|--------------------|---------------|-----------|
| SRR6063610 | NextSeq 500 | 150 bp PE | 112M | 33.8 Gb | 21.5 GiB | ~26x | SAMN07690466 |
| SRR6063611 | NextSeq 500 | 150 bp PE | 98M | 29.6 Gb | 18.8 GiB | ~23x | SAMN07690465 |
| SRR6063612 | NextSeq 500 | 150 bp PE | 101M | 30.4 Gb | 19.3 GiB | ~23x | SAMN07690468 |
| SRR6063613 | NextSeq 500 | 150 bp PE | 111M | 33.6 Gb | 21.3 GiB | ~26x | SAMN07690467 |
| SRR6118663 | HiSeq 2500 | ~200 bp PE | 517M | 104.4 Gb | 89.4 GiB | ~80x | SAMN07690447 |

**Subtotal:** 170.3 GiB (10 files)

### S3 File Naming Convention

```
raw/mosquito-wgs/{SRR_ACCESSION}/{SRR_ACCESSION}_R1.fastq.gz   # Forward reads
raw/mosquito-wgs/{SRR_ACCESSION}/{SRR_ACCESSION}_R2.fastq.gz   # Reverse reads
```

### Download Method

```bash
# SRA Toolkit v3.1.1
# Step 1: Prefetch (download SRA archive, restartable)
prefetch {SRR_ACCESSION} \
  --output-directory ./raw_fastq \
  --max-size 120G

# Step 2: Convert to paired FASTQ
fasterq-dump ./raw_fastq/{SRR_ACCESSION}/{SRR_ACCESSION}.sra \
  --outdir ./raw_fastq \
  --split-files \
  --threads 8 \
  --temp ./raw_fastq/tmp

# Step 3: Compress
pigz -p 8 ./raw_fastq/{SRR_ACCESSION}_1.fastq
pigz -p 8 ./raw_fastq/{SRR_ACCESSION}_2.fastq

# Step 4: Upload to S3
aws s3 cp ./raw_fastq/{SRR_ACCESSION}_1.fastq.gz \
  s3://BUCKET/raw/mosquito-wgs/{SRR_ACCESSION}/{SRR_ACCESSION}_R1.fastq.gz
aws s3 cp ./raw_fastq/{SRR_ACCESSION}_2.fastq.gz \
  s3://BUCKET/raw/mosquito-wgs/{SRR_ACCESSION}/{SRR_ACCESSION}_R2.fastq.gz
```

### BioProject PRJNA318737 — Full SRA Summary (216 runs total)

이 버킷에 저장된 5개 run은 **WGS Illumina paired-end** 데이터만 선별한 것이다.
BioProject 전체에는 아래와 같은 데이터가 존재한다:

| Category | Runs | Total Data | Platform | Layout |
|----------|------|------------|----------|--------|
| WGS PacBio (assembly reads) | 176 | 315.5 Gb | PacBio RS II | SINGLE |
| WGS Illumina (short-read) | 5 | 231.7 Gb | HiSeq 2500 / NextSeq 500 | PAIRED |
| Hi-C (chromosome scaffolding) | 2 | 109.8 Gb | HiSeq X Ten | PAIRED |
| 10X Chromium (linked-reads) | 32 | 234.3 Gb | HiSeq 2500 | PAIRED |
| **Total** | **216** | **891.3 Gb** | | |

---

## 3. Pipeline Scripts

**S3 Prefix:** `s3://<BUCKET>/scripts/`

| File | Size | Description |
|------|------|-------------|
| `01_prepare_reference.sh` | 4.2 KiB | Reference genome indexing (samtools, GATK, BWA-mem2) |
| `02_simulate_reads.sh` | 3.4 KiB | Test data generation with wgsim |
| `03_run_per_sample.sh` | 5.8 KiB | Per-sample pipeline (FastQC → FastP → BWA → Sort → Dedup → HaplotypeCaller) |
| `04_joint_genotyping.sh` | 5.5 KiB | Joint genotyping (GenomicsDBImport → GenotypeGVCFs → Filter) |
| `05_run_full_test.sh` | 5.0 KiB | End-to-end pipeline test runner |
| `restart_from_bwa.sh` | 5.0 KiB | Pipeline restart from BWA alignment step |

---

## 4. Test Results (Pilot)

**S3 Prefix:** `s3://<BUCKET>/results/gatk/`

| File | Size | Description |
|------|------|-------------|
| `test_cohort.raw.vcf.gz` | 20.3 KiB | Raw joint-called VCF (simulated data) |
| `test_cohort.filtered.vcf.gz` | 19.8 KiB | Filtered VCF (QD<5, FS>60, ReadPosRankSum<-8, GQ>20, DP>=10) |
| `test_cohort.filtered.vcf.gz.tbi` | 72 Bytes | Tabix index |

---

## 5. S3 Full Listing

```
<BUCKET>/
├── raw/
│   └── mosquito-wgs/
│       ├── SRR6063610/
│       │   ├── SRR6063610_R1.fastq.gz    (10.7 GiB)
│       │   └── SRR6063610_R2.fastq.gz    (10.8 GiB)
│       ├── SRR6063611/
│       │   ├── SRR6063611_R1.fastq.gz    ( 9.3 GiB)
│       │   └── SRR6063611_R2.fastq.gz    ( 9.5 GiB)
│       ├── SRR6063612/
│       │   ├── SRR6063612_R1.fastq.gz    ( 9.6 GiB)
│       │   └── SRR6063612_R2.fastq.gz    ( 9.7 GiB)
│       ├── SRR6063613/
│       │   ├── SRR6063613_R1.fastq.gz    (10.6 GiB)
│       │   └── SRR6063613_R2.fastq.gz    (10.7 GiB)
│       └── SRR6118663/
│           ├── SRR6118663_R1.fastq.gz    (44.3 GiB)
│           └── SRR6118663_R2.fastq.gz    (45.1 GiB)
├── reference/
│   └── mosquito/
│       └── AaegL5/
│           ├── AaegL5.fasta              ( 1.2 GiB)
│           ├── AaegL5.fasta.fai
│           ├── AaegL5.dict
│           ├── AaegL5.fasta.0123         ( 2.4 GiB)
│           ├── AaegL5.fasta.amb
│           ├── AaegL5.fasta.ann
│           ├── AaegL5.fasta.bwt.2bit.64  ( 3.9 GiB)
│           ├── AaegL5.fasta.pac          (304.9 MiB)
│           ├── AaegL5.gff3              (117.4 MiB)
│           ├── cds_from_genomic.fna
│           ├── protein.faa
│           ├── rna.fna
│           └── sequence_report.jsonl
├── results/
│   └── gatk/
│       ├── test_cohort.raw.vcf.gz
│       ├── test_cohort.filtered.vcf.gz
│       └── test_cohort.filtered.vcf.gz.tbi
└── scripts/
    ├── 01_prepare_reference.sh
    ├── 02_simulate_reads.sh
    ├── 03_run_per_sample.sh
    ├── 04_joint_genotyping.sh
    ├── 05_run_full_test.sh
    └── restart_from_bwa.sh
```

---

## Notes

- 모든 FASTQ는 SRA에서 다운로드 후 `pigz -p 8`로 압축하여 S3에 저장
- 로컬 사본은 S3 업로드 검증 후 전부 삭제 완료
- Coverage 계산: raw bases / genome size (1.279 Gb)
- SRR6118663 (~80x)은 단독으로 전체 파이프라인 테스트에 충분한 depth
- SRR6063610-613 (NextSeq 500, 각 ~23-26x)은 joint genotyping 테스트에 적합
- Reference genome의 BWA-mem2 인덱스는 별도 EC2에서 사전 생성되어 있었음
