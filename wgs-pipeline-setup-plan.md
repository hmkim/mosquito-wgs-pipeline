# WGS Pipeline Setup Plan — Ae. aegypti GATK Pipeline

**Date:** 2026-04-14
**Reference Document:** `genomics-pipeline-overview.md`
**Target:** Local execution on a dedicated EC2 instance, followed by AWS HealthOmics deployment

---

## 0. Prerequisites (EC2 Instance Requirements)

| Item | Recommended Spec | Notes |
|------|-----------------|-------|
| Instance type | r5.4xlarge (16 vCPU, 128 GB) or larger | BWA-mem2 indexing requires ~80 GB RAM |
| Storage | 500 GB gp3 EBS | Genome 1.3 GB + indices ~20 GB + BAM/gVCF workspace |
| OS | Amazon Linux 2023 or Ubuntu 22.04 | |
| Java | OpenJDK 17+ | Required by GATK 4.5 |

---

## Step 1. Tool Installation

### 1.1 Core Tools

```bash
# SAMtools 1.20 + HTSlib 1.20 (includes tabix)
sudo yum install -y autoconf automake make gcc zlib-devel bzip2-devel xz-devel curl-devel openssl-devel ncurses-devel
cd /tmp
wget https://github.com/samtools/samtools/releases/download/1.20/samtools-1.20.tar.bz2
tar -xjf samtools-1.20.tar.bz2 && cd samtools-1.20
./configure --prefix=/usr/local && make -j$(nproc) && sudo make install

# HTSlib (tabix, bgzip)
cd /tmp
wget https://github.com/samtools/htslib/releases/download/1.20/htslib-1.20.tar.bz2
tar -xjf htslib-1.20.tar.bz2 && cd htslib-1.20
./configure --prefix=/usr/local && make -j$(nproc) && sudo make install

# BCFtools 1.20
cd /tmp
wget https://github.com/samtools/bcftools/releases/download/1.20/bcftools-1.20.tar.bz2
tar -xjf bcftools-1.20.tar.bz2 && cd bcftools-1.20
make -j$(nproc) && sudo make install

# BWA-mem2 v2.2.1 (pre-built binary)
cd /opt
sudo wget -qO- https://github.com/bwa-mem2/bwa-mem2/releases/download/v2.2.1/bwa-mem2-2.2.1_x64-linux.tar.bz2 \
  | sudo tar -xjf -
echo 'export PATH="/opt/bwa-mem2-2.2.1_x64-linux:$PATH"' >> ~/.bashrc
source ~/.bashrc

# GATK 4.5.0.0
cd /opt
sudo wget https://github.com/broadinstitute/gatk/releases/download/4.5.0.0/gatk-4.5.0.0.zip
sudo unzip gatk-4.5.0.0.zip
echo 'export PATH="/opt/gatk-4.5.0.0:$PATH"' >> ~/.bashrc
source ~/.bashrc

# FastQC v0.12.1
cd /opt
sudo wget https://www.bioinformatics.babraham.ac.uk/projects/fastqc/fastqc_v0.12.1.zip
sudo unzip fastqc_v0.12.1.zip && sudo chmod +x /opt/FastQC/fastqc
sudo ln -s /opt/FastQC/fastqc /usr/local/bin/fastqc

# FastP (latest binary)
sudo wget -qO /usr/local/bin/fastp http://opengene.org/fastp/fastp
sudo chmod +x /usr/local/bin/fastp

# MultiQC
pip install multiqc==1.22
```

### 1.2 Simulation Tools (for testing)

```bash
# wgsim (included with samtools) or ART
# wgsim is built alongside samtools
which wgsim  # verify

# Alternative: ART (Illumina read simulator)
# wget https://www.niehs.nih.gov/research/resources/assets/docs/artbinmountrainier2016.06.05linux64.tgz
```

### 1.3 Installation Verification

```bash
samtools --version | head -1    # samtools 1.20
bcftools --version | head -1    # bcftools 1.20
bwa-mem2 version                # 2.2.1
gatk --version                  # 4.5.0.0
fastqc --version                # FastQC v0.12.1
fastp --version                 # fastp 0.23.x
multiqc --version               # multiqc, version 1.22
```

---

## Step 2. Reference Genome Preparation

### 2.1 Download Genome (already completed)

```bash
# NCBI datasets CLI
datasets download genome accession GCF_002204515.2 --include gff3,rna,cds,protein,genome,seq-report
unzip ncbi_dataset.zip
```

**Downloaded files location:** `genomes/ncbi_dataset/data/GCF_002204515.2/`

| File | Size | Description |
|------|------|-------------|
| `GCF_002204515.2_AaegL5.0_genomic.fna` | 1.3 GB | Reference FASTA (2,310 scaffolds, 3 chromosomes) |
| `genomic.gff` | 118 MB | Gene annotation |
| `cds_from_genomic.fna` | 68 MB | CDS sequences (28,317) |
| `protein.faa` | 22 MB | Protein sequences (28,317) |
| `rna.fna` | 100 MB | RNA sequences (33,013) |

### 2.2 Reference Directory Setup

```bash
mkdir -p reference/mosquito/AaegL5

# Copy and rename genome FASTA
cp genomes/ncbi_dataset/data/GCF_002204515.2/GCF_002204515.2_AaegL5.0_genomic.fna \
   reference/mosquito/AaegL5/AaegL5.fasta

# Copy GFF3 annotation
cp genomes/ncbi_dataset/data/GCF_002204515.2/genomic.gff \
   reference/mosquito/AaegL5/AaegL5.gff3
```

### 2.3 Index Generation

```bash
cd reference/mosquito/AaegL5

# 1) samtools faidx — FASTA index (.fai)
samtools faidx AaegL5.fasta
# Output: AaegL5.fasta.fai

# 2) GATK CreateSequenceDictionary — sequence dictionary (.dict)
gatk CreateSequenceDictionary -R AaegL5.fasta
# Output: AaegL5.dict

# 3) BWA-mem2 index — alignment index (5 files)
#    ** Note: requires ~80 GB RAM, takes ~30-60 min **
bwa-mem2 index AaegL5.fasta
# Output: AaegL5.fasta.{0123,amb,ann,bwt.2bit.64,pac}
```

### 2.4 Post-Indexing Verification

```bash
ls -lh reference/mosquito/AaegL5/

# Expected files:
# AaegL5.fasta          ~1.3 GB   Genome sequence
# AaegL5.fasta.fai      ~200 KB   samtools index
# AaegL5.dict           ~200 KB   GATK dictionary
# AaegL5.fasta.0123     ~2.6 GB   BWA-mem2 index
# AaegL5.fasta.amb      <1 KB     BWA-mem2
# AaegL5.fasta.ann      ~100 KB   BWA-mem2
# AaegL5.fasta.bwt.2bit.64  ~2.6 GB  BWA-mem2
# AaegL5.fasta.pac      ~650 MB   BWA-mem2

# Verify chromosome information
head -5 AaegL5.fasta.fai
# Expected output:
# NC_035107.1  310827022  ...  (chromosome 1)
# NC_035108.1  474425716  ...  (chromosome 2)
# NC_035109.1  409777670  ...  (chromosome 3)

# Verify dict file
head -5 AaegL5.dict
```

---

## Step 3. Test Data Generation

Validate the pipeline with simulated reads before using real sequencing data.

### 3.1 Small-Scale Test (partial chr1, ~5 min)

```bash
mkdir -p test_data

# Extract first 1 Mb of chr1 (NC_035107.1)
samtools faidx reference/mosquito/AaegL5/AaegL5.fasta NC_035107.1:1-1000000 \
  > test_data/chr1_1mb.fasta

# Generate paired-end reads with wgsim
# -N 50000: 50K read pairs
# -1 150 -2 150: 150bp paired-end
# -r 0.001: mutation rate 0.1%
# -R 0.1: indel fraction 10%
# -d 300: insert size 300bp
wgsim -N 50000 -1 150 -2 150 -r 0.001 -R 0.1 -d 300 -S 42 \
  test_data/chr1_1mb.fasta \
  test_data/test_R1.fastq \
  test_data/test_R2.fastq

# Compress
gzip test_data/test_R1.fastq test_data/test_R2.fastq

ls -lh test_data/
```

### 3.2 Medium-Scale Test (full chr1, ~10x, optional)

```bash
# Simulate 10x coverage over full chr1
# chr1 = 310 Mb, 10x = 3.1 Gb -> ~10.3M read pairs (150bp PE)
wgsim -N 10300000 -1 150 -2 150 -r 0.001 -R 0.1 -d 300 -S 42 \
  reference/mosquito/AaegL5/AaegL5.fasta \
  test_data/full_test_R1.fastq \
  test_data/full_test_R2.fastq

gzip test_data/full_test_R1.fastq test_data/full_test_R2.fastq
```

---

## Step 4. Per-Sample Pipeline (Local Execution)

Run each step of the WDL (`gatk-mosquito.wdl`) locally via bash.

### 4.1 Variable Setup

```bash
# Path configuration
SAMPLE_ID="test_sample_001"
REF_DIR="reference/mosquito/AaegL5"
REF="${REF_DIR}/AaegL5.fasta"
FASTQ_R1="test_data/test_R1.fastq.gz"
FASTQ_R2="test_data/test_R2.fastq.gz"
OUTDIR="results/gatk/${SAMPLE_ID}"

mkdir -p ${OUTDIR}
```

### 4.2 Step 1: FastQC (QC Report)

```bash
fastqc ${FASTQ_R1} ${FASTQ_R2} -o ${OUTDIR} --threads 2

# Verify: 2 HTML reports generated
ls ${OUTDIR}/*fastqc.html
```

### 4.3 Step 2: FastP (Trimming)

```bash
fastp \
  --in1 ${FASTQ_R1} \
  --in2 ${FASTQ_R2} \
  --out1 ${OUTDIR}/${SAMPLE_ID}_trimmed_R1.fastq.gz \
  --out2 ${OUTDIR}/${SAMPLE_ID}_trimmed_R2.fastq.gz \
  --html ${OUTDIR}/${SAMPLE_ID}_fastp.html \
  --json ${OUTDIR}/${SAMPLE_ID}_fastp.json \
  --thread 4 \
  --qualified_quality_phred 20 \
  --length_required 50

# Verify: trimmed reads file size > 0
ls -lh ${OUTDIR}/${SAMPLE_ID}_trimmed_*.fastq.gz
```

### 4.4 Step 3: BWA-mem2 Alignment

```bash
bwa-mem2 mem \
  -t 8 \
  -R "@RG\tID:${SAMPLE_ID}\tSM:${SAMPLE_ID}\tPL:ILLUMINA\tLB:lib1" \
  ${REF} \
  ${OUTDIR}/${SAMPLE_ID}_trimmed_R1.fastq.gz \
  ${OUTDIR}/${SAMPLE_ID}_trimmed_R2.fastq.gz \
| samtools view -bS - > ${OUTDIR}/${SAMPLE_ID}.aligned.bam

# Verify: BAM file created with read counts
samtools flagstat ${OUTDIR}/${SAMPLE_ID}.aligned.bam
```

### 4.5 Step 4: Sort & Index

```bash
samtools sort -@ 4 -o ${OUTDIR}/${SAMPLE_ID}.sorted.bam ${OUTDIR}/${SAMPLE_ID}.aligned.bam
samtools index ${OUTDIR}/${SAMPLE_ID}.sorted.bam

# Verify
samtools flagstat ${OUTDIR}/${SAMPLE_ID}.sorted.bam
ls -lh ${OUTDIR}/${SAMPLE_ID}.sorted.bam*
```

### 4.6 Step 5: MarkDuplicates

```bash
gatk MarkDuplicates \
  -I ${OUTDIR}/${SAMPLE_ID}.sorted.bam \
  -O ${OUTDIR}/${SAMPLE_ID}.dedup.bam \
  -M ${OUTDIR}/${SAMPLE_ID}.dedup_metrics.txt \
  --REMOVE_DUPLICATES false \
  --CREATE_INDEX true

# Verify: check dedup metrics
cat ${OUTDIR}/${SAMPLE_ID}.dedup_metrics.txt | grep -A 2 "LIBRARY"
```

### 4.7 Step 6: HaplotypeCaller (gVCF Generation)

```bash
gatk HaplotypeCaller \
  -R ${REF} \
  -I ${OUTDIR}/${SAMPLE_ID}.dedup.bam \
  -O ${OUTDIR}/${SAMPLE_ID}.g.vcf.gz \
  -ERC GVCF \
  --min-base-quality-score 20

# Verify: gVCF file and index
ls -lh ${OUTDIR}/${SAMPLE_ID}.g.vcf.gz*
bcftools stats ${OUTDIR}/${SAMPLE_ID}.g.vcf.gz | head -30
```

---

## Step 5. Joint Genotyping (Multi-Sample)

Consolidate per-sample gVCFs for cohort-level variant calling.
(Requires gVCFs from at least 2 samples)

### 5.1 GenomicsDBImport

```bash
COHORT="test_cohort"

# Create sample map (sample_name \t gvcf_path)
echo -e "test_sample_001\tresults/gatk/test_sample_001/test_sample_001.g.vcf.gz" > sample_map.txt
echo -e "test_sample_002\tresults/gatk/test_sample_002/test_sample_002.g.vcf.gz" >> sample_map.txt

# Intervals list: 3 chromosomes
echo -e "NC_035107.1\nNC_035108.1\nNC_035109.1" > intervals.list

gatk GenomicsDBImport \
  --sample-name-map sample_map.txt \
  --genomicsdb-workspace-path genomicsdb_${COHORT} \
  --reader-threads 4 \
  --batch-size 50 \
  -R ${REF} \
  -L intervals.list
```

### 5.2 GenotypeGVCFs

```bash
gatk GenotypeGVCFs \
  -R ${REF} \
  -V gendb://genomicsdb_${COHORT} \
  -O results/gatk/${COHORT}.raw.vcf.gz
```

### 5.3 Variant Filtering (based on reference paper)

```bash
# SNP filtering criteria (Nature Communications 2025):
# QD < 5, FS > 60, ReadPosRankSum < -8 -> site-level
# GQ > 20, DP >= 10 -> genotype-level

bcftools filter \
  -e 'INFO/QD < 5 || INFO/FS > 60 || INFO/ReadPosRankSum < -8' \
  results/gatk/${COHORT}.raw.vcf.gz | \
bcftools view \
  -i 'FORMAT/GQ > 20 && FORMAT/DP >= 10' \
  -Oz -o results/gatk/${COHORT}.filtered.vcf.gz

tabix -p vcf results/gatk/${COHORT}.filtered.vcf.gz

# Verify: variant counts
bcftools stats results/gatk/${COHORT}.filtered.vcf.gz | grep "^SN"
```

---

## Step 6. Pipeline Validation Checklist

Expected outputs and success criteria for each step:

| Step | Output | Success Criteria |
|------|--------|-----------------|
| Reference prep | `.fasta`, `.fai`, `.dict`, 5 BWA index files | All files present, `samtools faidx` runs without error |
| FastQC | `*_fastqc.html` x 2 | HTML reports generated successfully |
| FastP | `*_trimmed_R{1,2}.fastq.gz` | File size > 0, pass rate > 80% |
| BWA-mem2 | `.aligned.bam` | Mapping rate > 90% (simulated data) |
| Sort & Index | `.sorted.bam`, `.sorted.bam.bai` | BAM index valid |
| MarkDuplicates | `.dedup.bam`, `_metrics.txt` | Duplication rate recorded |
| HaplotypeCaller | `.g.vcf.gz`, `.g.vcf.gz.tbi` | Variant records present in gVCF |
| GenomicsDBImport | `genomicsdb_*` directory | Workspace directory created |
| GenotypeGVCFs | `.raw.vcf.gz` | VCF header + variant lines present |
| FilterVariants | `.filtered.vcf.gz`, `.tbi` | PASS variant count > 0 |

---

## Step 7. Target Directory Structure

```
project-NEA-EHI/
├── reference/
│   └── mosquito/
│       └── AaegL5/
│           ├── AaegL5.fasta              # Genome sequence
│           ├── AaegL5.fasta.fai          # samtools index
│           ├── AaegL5.dict               # GATK dictionary
│           ├── AaegL5.fasta.0123         # BWA-mem2 index
│           ├── AaegL5.fasta.amb          # BWA-mem2
│           ├── AaegL5.fasta.ann          # BWA-mem2
│           ├── AaegL5.fasta.bwt.2bit.64  # BWA-mem2
│           ├── AaegL5.fasta.pac          # BWA-mem2
│           └── AaegL5.gff3              # Gene annotation
├── test_data/
│   ├── test_R1.fastq.gz                 # Simulated reads
│   └── test_R2.fastq.gz
├── results/
│   └── gatk/
│       ├── test_sample_001/
│       │   ├── *_fastqc.html
│       │   ├── *_fastp.html
│       │   ├── *.dedup.bam
│       │   ├── *.dedup_metrics.txt
│       │   └── *.g.vcf.gz
│       └── test_cohort.filtered.vcf.gz
├── workflows/
│   └── gatk/
│       ├── gatk-mosquito.wdl             # Per-sample WDL
│       ├── joint-genotyping.wdl          # Joint genotyping WDL
│       └── Dockerfile                    # Container definition
├── scripts/
│   ├── 01_prepare_reference.sh           # Step 2 automation
│   ├── 02_simulate_reads.sh              # Step 3 automation
│   ├── 03_run_per_sample.sh              # Step 4 automation
│   └── 04_joint_genotyping.sh            # Step 5 automation
├── genomics-pipeline-overview.md
└── wgs-pipeline-setup-plan.md            # This document
```

---

## Step 8. AWS HealthOmics Deployment (after pipeline validation)

Production deployment steps after local testing is complete:

### 8.1 Build Docker Image and Push to ECR

```bash
# Create ECR repository
aws ecr create-repository --repository-name nea-ehi-gatk --region <REGION>

# Build Docker image (using existing Dockerfile)
cd workflows/gatk
docker build -t nea-ehi-gatk:latest .

# Login to ECR and push
aws ecr get-login-password --region <REGION> | \
  docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com
docker tag nea-ehi-gatk:latest <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/nea-ehi-gatk:latest
docker push <ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/nea-ehi-gatk:latest
```

### 8.2 Update WDL Docker Image Path

Update the docker value in all runtime blocks of `gatk-mosquito.wdl` and `joint-genotyping.wdl`:

```
# Before
docker: "ECR_REPO_URI/nea-ehi-gatk:latest"

# After
docker: "<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/nea-ehi-gatk:latest"
```

### 8.3 Upload Reference Data to S3

```bash
# Upload AaegL5 reference + indices to S3
aws s3 sync reference/mosquito/AaegL5/ s3://<BUCKET>/reference/mosquito/AaegL5/
```

### 8.4 Create and Run HealthOmics Workflow

```bash
# Register WDL workflow
aws omics create-workflow \
  --name gatk-mosquito-wgs \
  --engine WDL \
  --definition-zip fileb://workflows/gatk/gatk-mosquito-workflow.zip \
  --main gatk-mosquito.wdl \
  --region <REGION>

# Start workflow run
aws omics start-run \
  --workflow-id <WORKFLOW_ID> \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/nea-ehi-omics-workflow-role \
  --parameters file://run-inputs-SRR6063611.json \
  --output-uri s3://<BUCKET>/omics-output/ \
  --storage-type DYNAMIC \
  --log-level ALL \
  --region <REGION>
```

---

## Reference Notes

### Genome Assembly Information

- **Assembly:** AaegL5.0 (GCF_002204515.2)
- **Species:** *Aedes aegypti* (yellow fever mosquito)
- **Strain:** LVP_AGWG (inbred laboratory strain)
- **Total length:** 1.279 Gb
- **Scaffolds:** 2,310
- **Chromosomes:** 3 (NC_035107.1, NC_035108.1, NC_035109.1)
- **Genes:** 18,580 (NCBI Annotation Release 101)
- **GC content:** 0.382 +/- 0.029

### Relationship to Morinaga et al. (GBE 2025)

As noted by Morinaga et al. (GBE 2025), AaegL5 is derived from an inbred laboratory strain and may not fully represent wild mosquito populations. When the wild *Ae. aegypti formosus* (Aaf) genome becomes available on NCBI (SRR33810828), it could serve as an alternative reference or be used for liftover analysis.

### SNP Filtering Criteria Source

Nature Communications 2025 (doi:10.1038/s41467-025-62693-y):
"Dengue virus susceptibility in *Aedes aegypti* linked to natural cytochrome P450 promoter variants"

| Filter | Threshold | Purpose |
|--------|-----------|---------|
| QD | < 5 | Quality by Depth — remove low-confidence variants |
| FS | > 60 | Fisher Strand Bias — remove strand bias |
| ReadPosRankSum | < -8 | Read position rank sum — remove read-end position bias |
| GQ | > 20 | Genotype Quality — individual genotype confidence |
| DP | >= 10 | Minimum read depth (10x) |
