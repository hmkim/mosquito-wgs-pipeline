# Parabricks on AWS Batch 실행 계획

> 작성일: 2026-04-24  
> 완료일: 2026-04-26  
> 배경: HealthOmics PRIVATE 워크플로에서 haplotypecaller가 반복 실패 (T4 CUDA OOM).  
> 최종 결과: **g5.12xlarge (4x A10G)에서 37분 완료, $3.66/sample**

## 목표

AWS Batch + GPU 인스턴스에서 Parabricks germline pipeline (fq2bam → haplotypecaller) 실행하여 
*Ae. aegypti* SRR6063611 샘플의 variant calling 완료.

## 현재 보유 리소스

| 항목 | 상태 | 위치 |
|---|---|---|
| ECR 이미지 | `parabricks:4.3.1-1` ✅ | `664263524008.dkr.ecr.ap-northeast-2.amazonaws.com` |
| FASTQ R1 | 9.9 GB ✅ | `s3://nea-ehi-wgs-data-.../raw/mosquito-wgs/SRR6063611/SRR6063611_R1.fastq.gz` |
| FASTQ R2 | 10.1 GB ✅ | `s3://nea-ehi-wgs-data-.../raw/mosquito-wgs/SRR6063611/SRR6063611_R2.fastq.gz` |
| Reference tarball | 3.3 GB ✅ | `s3://nea-ehi-wgs-data-.../reference/mosquito/AaegL5/AaegL5.fasta.tar` |
| EC2 인스턴스 | `i-0b0068e92b2060948` ✅ | ap-northeast-2 |

## 아키텍처

```
S3 (input)
    ↓  s3 cp / mountpoint
┌──────────────────────────────┐
│  AWS Batch (GPU Compute Env) │
│  G4dn.12xlarge (4x T4 GPU)  │
│                              │
│  Step 1: fq2bam              │
│    FASTQ → BAM + BAI         │
│                              │
│  Step 2: haplotypecaller     │
│    BAM → GVCF                │
│                              │
│  (단일 Job에서 순차 실행)      │
└──────────────────────────────┘
    ↓  s3 cp
S3 (output)
```

## 실행 단계

### Phase 1: 인프라 구성

#### 1-1. VPC/서브넷 확인
- 기존 VPC의 퍼블릭 서브넷 사용 (S3 접근 필요)
- 또는 VPC Endpoint (S3 Gateway) 설정된 프라이빗 서브넷

#### 1-2. Batch Compute Environment 생성
- **타입**: MANAGED
- **인스턴스 타입**: `g4dn.12xlarge` (4x T4, 48 vCPU, 192 GiB)
- **AMI**: ECS GPU-optimized AMI (NVIDIA 드라이버 포함)
- **Min/Max vCPU**: 0 / 48 (사용 안 할 때 0으로 스케일다운)
- **Spot 인스턴스** 옵션: 비용 절감 가능 (중단 리스크 있음)

#### 1-3. Job Queue 생성
- Compute Environment에 연결

#### 1-4. IAM 역할
- **Execution Role**: ECR pull 권한
- **Job Role**: S3 read/write 권한 (`nea-ehi-wgs-data-*` 버킷)

### Phase 2: Job Definition 작성

단일 Job에서 fq2bam + haplotypecaller를 순차 실행하는 방식.
(두 단계 모두 동일한 GPU 인스턴스가 필요하므로 분리하면 중간 데이터 전송 오버헤드 발생)

```bash
#!/bin/bash
set -euxo pipefail

# 1. S3에서 데이터 다운로드
aws s3 cp s3://BUCKET/reference/mosquito/AaegL5/AaegL5.fasta.tar /workdir/
aws s3 cp s3://BUCKET/raw/mosquito-wgs/SRR6063611/SRR6063611_R1.fastq.gz /workdir/
aws s3 cp s3://BUCKET/raw/mosquito-wgs/SRR6063611/SRR6063611_R2.fastq.gz /workdir/

# 2. Reference 압축 해제
cd /workdir
tar xf AaegL5.fasta.tar

# 3. fq2bam (FASTQ → BAM)
pbrun fq2bam \
  --ref AaegL5.fasta \
  --in-fq SRR6063611_R1.fastq.gz SRR6063611_R2.fastq.gz \
  "@RG\tID:SRR6063611\tLB:lib1\tPL:ILLUMINA\tSM:SRR6063611\tPU:unit1" \
  --out-bam SRR6063611.pb.bam \
  --tmp-dir /workdir/tmp_fq2bam \
  --low-memory

# 4. haplotypecaller (BAM → GVCF)
pbrun haplotypecaller \
  --ref AaegL5.fasta \
  --in-bam SRR6063611.pb.bam \
  --out-variants SRR6063611.g.vcf \
  --gvcf

# 5. 결과 업로드
aws s3 cp SRR6063611.pb.bam s3://BUCKET/output/parabricks-batch/
aws s3 cp SRR6063611.pb.bam.bai s3://BUCKET/output/parabricks-batch/
aws s3 cp SRR6063611.g.vcf s3://BUCKET/output/parabricks-batch/
```

### Phase 3: 실행 및 모니터링

#### 3-1. Job Submit
```bash
aws batch submit-job \
  --job-name parabricks-germline-SRR6063611 \
  --job-queue gpu-parabricks-queue \
  --job-definition parabricks-germline
```

#### 3-2. 모니터링
- CloudWatch Logs로 실시간 로그 확인
- `aws batch describe-jobs`로 상태 확인

### Phase 4: 결과 검증
- BAM 파일 크기 및 flagstat
- GVCF variant count
- HealthOmics fq2bam 결과와 비교 (동일 입력이므로 BAM이 동일해야 함)

## 스토리지 전략

| 옵션 | 장점 | 단점 |
|---|---|---|
| **S3 cp (권장)** | 단순, 추가 인프라 불필요 | 다운로드/업로드 시간 소요 |
| EBS (인스턴스 스토리지) | g4dn.12xlarge에 900GB NVMe 탑재 | Job별 새로 다운로드 |
| EFS | 재사용 가능 | 처리량 제한, 추가 비용 |

**권장**: g4dn.12xlarge의 로컬 NVMe SSD (900 GB) + S3 cp. 
입력 데이터 ~23 GB + reference 3.3 GB + 중간/출력 ~50 GB = ~76 GB로 충분.

## 비용 (실제 결과)

| 항목 | g4dn.12xlarge (T4) | g5.12xlarge (A10G) |
|---|---|---|
| 시간당 요금 (On-Demand) | $3.91/hr | $5.67/hr |
| fq2bam | 31분 OK | **14분 OK** |
| haplotypecaller | **CUDA OOM 실패** | **23분 OK** |
| 총 파이프라인 시간 | — | **37분** |
| 총 Job 시간 (데이터 전송 포함) | — | **44분** |
| **실제 비용 (On-Demand)** | — | **~$3.66** |
| **예상 비용 (Spot ~60%)** | — | **~$1.40** |

## 리스크 및 대응 (실제 경험)

| 리스크 | 실제 결과 | 대응 |
|---|---|---|
| g4dn T4 GPU 메모리 부족 | **발생** — HC에서 CUDA OOM | g5.12xlarge (A10G 24GiB)로 전환하여 해결 |
| NVIDIA 드라이버 호환 | 문제 없음 | ECS GPU AMI 정상 |
| 로컬 디스크 공간 부족 | v2에서 발생 | Launch template UserData로 NVMe 포맷/마운트 |
| 컨테이너에 AWS CLI 없음 | v1에서 발생 (exit 127) | `pip install awscli` 추가 |

## 타임라인

| 단계 | 예상 시간 |
|---|---|
| Phase 1: 인프라 구성 | ~20분 |
| Phase 2: Job Definition | ~10분 |
| Phase 3: 실행 | ~1시간 |
| Phase 4: 검증 | ~10분 |
| **합계** | **~1.5시간** |
