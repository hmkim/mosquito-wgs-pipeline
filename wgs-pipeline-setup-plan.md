# WGS Pipeline Setup Plan — Ae. aegypti GATK Pipeline

**Date:** 2026-04-14
**Reference Document:** `genomics-pipeline-overview.md`
**Target:** 별도 EC2 인스턴스에서 로컬 실행 후, AWS HealthOmics 배포

---

## 0. 사전 조건 (EC2 인스턴스 요구사항)

| 항목 | 권장 사양 | 비고 |
|------|----------|------|
| Instance type | r5.4xlarge (16 vCPU, 128 GB) 이상 | BWA-mem2 indexing에 ~80 GB RAM 필요 |
| Storage | 500 GB gp3 EBS | 게놈 1.3 GB + 인덱스 ~20 GB + BAM/gVCF 작업 공간 |
| OS | Amazon Linux 2023 또는 Ubuntu 22.04 | |
| Java | OpenJDK 17+ | GATK 4.5 요구사항 |

---

## 1단계. 도구 설치

### 1.1 핵심 도구

```bash
# SAMtools 1.20 + HTSlib 1.20 (tabix 포함)
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

### 1.2 시뮬레이션 도구 (테스트용)

```bash
# wgsim (samtools에 포함) 또는 ART
# wgsim은 samtools 설치 시 함께 빌드됨
which wgsim  # 확인

# 대안: ART (Illumina read simulator)
# wget https://www.niehs.nih.gov/research/resources/assets/docs/artbinmountrainier2016.06.05linux64.tgz
```

### 1.3 설치 검증

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

## 2단계. Reference Genome 준비

### 2.1 게놈 다운로드 (이미 완료)

```bash
# NCBI datasets CLI
datasets download genome accession GCF_002204515.2 --include gff3,rna,cds,protein,genome,seq-report
unzip ncbi_dataset.zip
```

**다운로드된 파일 위치:** `genomes/ncbi_dataset/data/GCF_002204515.2/`

| 파일 | 크기 | 용도 |
|------|------|------|
| `GCF_002204515.2_AaegL5.0_genomic.fna` | 1.3 GB | Reference FASTA (2,310 scaffolds, 3 chromosomes) |
| `genomic.gff` | 118 MB | Gene annotation |
| `cds_from_genomic.fna` | 68 MB | CDS 서열 (28,317개) |
| `protein.faa` | 22 MB | 단백질 서열 (28,317개) |
| `rna.fna` | 100 MB | RNA 서열 (33,013개) |

### 2.2 Reference 디렉토리 구성

```bash
mkdir -p reference/mosquito/AaegL5

# 게놈 FASTA 복사 및 이름 정리
cp genomes/ncbi_dataset/data/GCF_002204515.2/GCF_002204515.2_AaegL5.0_genomic.fna \
   reference/mosquito/AaegL5/AaegL5.fasta

# GFF3 복사
cp genomes/ncbi_dataset/data/GCF_002204515.2/genomic.gff \
   reference/mosquito/AaegL5/AaegL5.gff3
```

### 2.3 인덱스 생성

```bash
cd reference/mosquito/AaegL5

# 1) samtools faidx — FASTA 인덱스 (.fai)
samtools faidx AaegL5.fasta
# 출력: AaegL5.fasta.fai

# 2) GATK CreateSequenceDictionary — 시퀀스 딕셔너리 (.dict)
gatk CreateSequenceDictionary -R AaegL5.fasta
# 출력: AaegL5.dict

# 3) BWA-mem2 index — 정렬용 인덱스 (5개 파일)
#    ** 주의: ~80 GB RAM 필요, 약 30-60분 소요 **
bwa-mem2 index AaegL5.fasta
# 출력: AaegL5.fasta.{0123,amb,ann,bwt.2bit.64,pac}
```

### 2.4 인덱스 생성 후 검증

```bash
ls -lh reference/mosquito/AaegL5/

# 예상 파일 목록:
# AaegL5.fasta          ~1.3 GB   게놈 서열
# AaegL5.fasta.fai      ~200 KB   samtools 인덱스
# AaegL5.dict           ~200 KB   GATK 딕셔너리
# AaegL5.fasta.0123     ~2.6 GB   BWA-mem2 인덱스
# AaegL5.fasta.amb      <1 KB     BWA-mem2
# AaegL5.fasta.ann      ~100 KB   BWA-mem2
# AaegL5.fasta.bwt.2bit.64  ~2.6 GB  BWA-mem2
# AaegL5.fasta.pac      ~650 MB   BWA-mem2

# 염색체 정보 확인
head -5 AaegL5.fasta.fai
# 예상 출력:
# NC_035107.1  310827022  ...  (chromosome 1)
# NC_035108.1  474425716  ...  (chromosome 2)
# NC_035109.1  409777670  ...  (chromosome 3)

# dict 파일 확인
head -5 AaegL5.dict
```

---

## 3단계. 테스트 데이터 생성

실제 시퀀싱 데이터 대신 시뮬레이션 reads로 파이프라인을 검증한다.

### 3.1 소규모 테스트 (chr1 일부 구간, ~5분)

```bash
mkdir -p test_data

# chr1 (NC_035107.1) 처음 1 Mb 구간 추출
samtools faidx reference/mosquito/AaegL5/AaegL5.fasta NC_035107.1:1-1000000 \
  > test_data/chr1_1mb.fasta

# wgsim으로 paired-end reads 생성
# -N 50000: 50K read pairs
# -1 150 -2 150: 150bp paired-end
# -r 0.001: mutation rate 0.1%
# -R 0.1: indel fraction 10%
# -d 300: insert size 300bp
wgsim -N 50000 -1 150 -2 150 -r 0.001 -R 0.1 -d 300 -S 42 \
  test_data/chr1_1mb.fasta \
  test_data/test_R1.fastq \
  test_data/test_R2.fastq

# gzip 압축
gzip test_data/test_R1.fastq test_data/test_R2.fastq

ls -lh test_data/
```

### 3.2 중규모 테스트 (전체 chr1, ~10x, 선택사항)

```bash
# 전체 chr1 대상 10x coverage 시뮬레이션
# chr1 = 310 Mb, 10x = 3.1 Gb → ~10.3M read pairs (150bp PE)
wgsim -N 10300000 -1 150 -2 150 -r 0.001 -R 0.1 -d 300 -S 42 \
  reference/mosquito/AaegL5/AaegL5.fasta \
  test_data/full_test_R1.fastq \
  test_data/full_test_R2.fastq

gzip test_data/full_test_R1.fastq test_data/full_test_R2.fastq
```

---

## 4단계. Per-Sample Pipeline 로컬 실행

WDL (`gatk-mosquito.wdl`)의 각 단계를 로컬 bash로 실행한다.

### 4.1 변수 설정

```bash
# 경로 설정
SAMPLE_ID="test_sample_001"
REF_DIR="reference/mosquito/AaegL5"
REF="${REF_DIR}/AaegL5.fasta"
FASTQ_R1="test_data/test_R1.fastq.gz"
FASTQ_R2="test_data/test_R2.fastq.gz"
OUTDIR="results/gatk/${SAMPLE_ID}"

mkdir -p ${OUTDIR}
```

### 4.2 Step 1: FastQC (QC 리포트)

```bash
fastqc ${FASTQ_R1} ${FASTQ_R2} -o ${OUTDIR} --threads 2

# 검증: HTML 리포트 2개 생성 확인
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

# 검증: trimmed reads 파일 크기 > 0
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

# 검증: BAM 파일 생성 및 read count
samtools flagstat ${OUTDIR}/${SAMPLE_ID}.aligned.bam
```

### 4.5 Step 4: Sort & Index

```bash
samtools sort -@ 4 -o ${OUTDIR}/${SAMPLE_ID}.sorted.bam ${OUTDIR}/${SAMPLE_ID}.aligned.bam
samtools index ${OUTDIR}/${SAMPLE_ID}.sorted.bam

# 검증
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

# 검증: dedup metrics 확인
cat ${OUTDIR}/${SAMPLE_ID}.dedup_metrics.txt | grep -A 2 "LIBRARY"
```

### 4.7 Step 6: HaplotypeCaller (gVCF 생성)

```bash
gatk HaplotypeCaller \
  -R ${REF} \
  -I ${OUTDIR}/${SAMPLE_ID}.dedup.bam \
  -O ${OUTDIR}/${SAMPLE_ID}.g.vcf.gz \
  -ERC GVCF \
  --min-base-quality-score 20

# 검증: gVCF 파일 및 인덱스 확인
ls -lh ${OUTDIR}/${SAMPLE_ID}.g.vcf.gz*
bcftools stats ${OUTDIR}/${SAMPLE_ID}.g.vcf.gz | head -30
```

---

## 5단계. Joint Genotyping (다중 샘플)

여러 샘플의 gVCF를 통합하여 cohort-level variant calling 수행.
(최소 2개 이상 샘플의 gVCF가 필요)

### 5.1 GenomicsDBImport

```bash
COHORT="test_cohort"

# sample map 생성 (sample_name \t gvcf_path)
echo -e "test_sample_001\tresults/gatk/test_sample_001/test_sample_001.g.vcf.gz" > sample_map.txt
echo -e "test_sample_002\tresults/gatk/test_sample_002/test_sample_002.g.vcf.gz" >> sample_map.txt

# intervals list: 3 chromosomes
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

### 5.3 Variant Filtering (논문 기준)

```bash
# SNP 필터링 기준 (Nature Communications 2025 논문):
# QD < 5, FS > 60, ReadPosRankSum < -8 → site-level
# GQ > 20, DP >= 10 → genotype-level

bcftools filter \
  -e 'INFO/QD < 5 || INFO/FS > 60 || INFO/ReadPosRankSum < -8' \
  results/gatk/${COHORT}.raw.vcf.gz | \
bcftools view \
  -i 'FORMAT/GQ > 20 && FORMAT/DP >= 10' \
  -Oz -o results/gatk/${COHORT}.filtered.vcf.gz

tabix -p vcf results/gatk/${COHORT}.filtered.vcf.gz

# 검증: variant 수 확인
bcftools stats results/gatk/${COHORT}.filtered.vcf.gz | grep "^SN"
```

---

## 6단계. 파이프라인 검증 체크리스트

각 단계별 산출물과 성공 기준:

| 단계 | 산출물 | 성공 기준 |
|------|--------|----------|
| Reference 준비 | `.fasta`, `.fai`, `.dict`, BWA 인덱스 5개 | 모든 파일 존재, `samtools faidx` 오류 없음 |
| FastQC | `*_fastqc.html` x 2 | HTML 리포트 정상 생성 |
| FastP | `*_trimmed_R{1,2}.fastq.gz` | 파일 크기 > 0, pass rate > 80% |
| BWA-mem2 | `.aligned.bam` | mapping rate > 90% (시뮬레이션 데이터) |
| Sort & Index | `.sorted.bam`, `.sorted.bam.bai` | BAM index 정상 |
| MarkDuplicates | `.dedup.bam`, `_metrics.txt` | duplication rate 기록됨 |
| HaplotypeCaller | `.g.vcf.gz`, `.g.vcf.gz.tbi` | gVCF 내 variant record 존재 |
| GenomicsDBImport | `genomicsdb_*` 디렉토리 | workspace 디렉토리 생성 |
| GenotypeGVCFs | `.raw.vcf.gz` | VCF 헤더 + variant lines 존재 |
| FilterVariants | `.filtered.vcf.gz`, `.tbi` | PASS variant count > 0 |

---

## 7단계. 최종 디렉토리 구조 (목표)

```
project-NEA-EHI/
├── reference/
│   └── mosquito/
│       └── AaegL5/
│           ├── AaegL5.fasta              # 게놈 서열
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
│   ├── 01_prepare_reference.sh           # 2단계 자동화
│   ├── 02_simulate_reads.sh              # 3단계 자동화
│   ├── 03_run_per_sample.sh              # 4단계 자동화
│   └── 04_joint_genotyping.sh            # 5단계 자동화
├── genomics-pipeline-overview.md
└── wgs-pipeline-setup-plan.md            # 이 문서
```

---

## 8단계. AWS HealthOmics 배포 (파이프라인 검증 후)

로컬 테스트 완료 후 프로덕션 배포 단계:

### 8.1 Docker 이미지 빌드 및 ECR 푸시

```bash
# ECR 리포지토리 생성
aws ecr create-repository --repository-name nea-ehi-gatk --region ap-southeast-1

# Docker 빌드 (기존 Dockerfile 사용)
cd workflows/gatk
docker build -t nea-ehi-gatk:latest .

# ECR 로그인 및 푸시
aws ecr get-login-password --region ap-southeast-1 | \
  docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com
docker tag nea-ehi-gatk:latest <ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com/nea-ehi-gatk:latest
docker push <ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com/nea-ehi-gatk:latest
```

### 8.2 WDL docker 경로 업데이트

`gatk-mosquito.wdl` 및 `joint-genotyping.wdl` 내 모든 runtime 블록의 docker 값 변경:

```
# 변경 전
docker: "ECR_REPO_URI/nea-ehi-gatk:latest"

# 변경 후
docker: "<ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com/nea-ehi-gatk:latest"
```

### 8.3 Reference Store 등록

```bash
# AaegL5 + 인덱스를 S3에 업로드
aws s3 sync reference/mosquito/AaegL5/ s3://nea-ehi-poc-data-<ACCOUNT>/reference/mosquito/AaegL5/

# HealthOmics Reference Store에 등록
aws omics create-reference-store --name nea-ehi-reference-store
aws omics start-reference-import-job \
  --reference-store-id <STORE_ID> \
  --sources sourceFile=s3://nea-ehi-poc-data-<ACCOUNT>/reference/mosquito/AaegL5/AaegL5.fasta
```

### 8.4 HealthOmics Workflow 생성 및 실행

```bash
# WDL 워크플로우 등록
aws omics create-workflow \
  --name gatk-mosquito-wgs \
  --engine WDL \
  --definition-zip workflows/gatk/gatk-mosquito.zip \
  --parameter-template file://workflows/gatk/params-template.json

# 워크플로우 실행
aws omics start-run \
  --workflow-id <WORKFLOW_ID> \
  --role-arn <EXECUTION_ROLE_ARN> \
  --parameters file://run-params.json \
  --output-uri s3://nea-ehi-poc-data-<ACCOUNT>/results/gatk/
```

---

## 참고 사항

### 게놈 어셈블리 정보

- **어셈블리:** AaegL5.0 (GCF_002204515.2)
- **종:** *Aedes aegypti* (황열 모기)
- **Strain:** LVP_AGWG (inbred laboratory strain)
- **총 길이:** 1.279 Gb
- **Scaffold 수:** 2,310
- **Chromosome:** 3개 (NC_035107.1, NC_035108.1, NC_035109.1)
- **유전자 수:** 18,580 (NCBI Annotation Release 101)
- **GC 함량:** 0.382 ± 0.029

### evaf142.pdf 논문과의 관계

Morinaga et al. (GBE 2025) 논문에서 지적한 바와 같이, AaegL5는 근교된 실험실 계통 유래로 야생 모기를 대표하지 못하는 한계가 있다. 향후 야생 *Ae. aegypti formosus* (Aaf) 게놈이 NCBI에 공개되면 (SRR33810828), 이를 대안 reference로 활용하거나 liftover 분석에 사용할 수 있다.

### SNP 필터링 기준 출처

Nature Communications 2025 논문 (doi:10.1038/s41467-025-62693-y):
"Dengue virus susceptibility in *Aedes aegypti* linked to natural cytochrome P450 promoter variants"

| 필터 | 임계값 | 목적 |
|------|--------|------|
| QD | < 5 | Quality by Depth — 낮은 신뢰도 variant 제거 |
| FS | > 60 | Fisher Strand Bias — 가닥 편향 제거 |
| ReadPosRankSum | < -8 | Read 말단 위치 편향 제거 |
| GQ | > 20 | Genotype Quality — 개별 유전형 신뢰도 |
| DP | >= 10 | 최소 read depth (10x) |
