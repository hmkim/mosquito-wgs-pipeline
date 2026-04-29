# HaplotypeCaller Concordance Benchmarking Plan

**Date:** 2026-04-27  
**Sample:** SRR6063611 (*Aedes aegypti*, ~23x WGS, AaegL5 1.279 Gbp)  
**Reference:** Samarakoon et al. 2025 (*Bioinformatics Advances*, vbaf085)

---

## 1. Background

Samarakoon et al. 2025는 CPU-only GATK, Parabricks GPU, DRAGEN FPGA 파이프라인을 Illumina Platinum Genomes truth set 기반으로 벤치마크했다. Parabricks HC는 CPU-only HC 대비 near-perfect concordance를 보였다:

| Metric | 논문 결과 (Figure 5C/D) |
|---|---|
| SNV F1 | > 0.975, median ~0.995 |
| Indel F1 | > 0.975, wider spread |
| GPU tested | L4 (24GB), A100 (40GB), H100 (80GB) |
| Parabricks version | 4.3.0-1 |

우리 프로젝트는 *Ae. aegypti* (비모델생물)로 gold-standard truth set이 없으므로, 논문의 **concordance analysis** 방법론만 적용 가능하다. EC2 CPU GATK HC를 baseline(truth)으로 지정하고, Parabricks GPU HC 및 HealthOmics CPU HC 결과와의 concordance를 측정한다.

**목표:** 4개 HC 결과 간 variant-level concordance를 정량화하여 GPU 파이프라인 결과의 신뢰성 검증.

---

## 2. Comparisons

| ID | Query | Baseline | 질문 |
|---|---|---|---|
| **COMP-A** | Parabricks GPU HC (Batch g5.12xlarge) | EC2 CPU GATK HC | GPU vs CPU HC concordance (핵심) |
| **COMP-B** | HealthOmics BWA-mem2 HC (Run 6185205) | EC2 CPU GATK HC | 플랫폼 간 일관성 |
| **COMP-C** | HealthOmics BWA v0.7.19 HC (Run 6503897) | HealthOmics BWA-mem2 HC (Run 6185205) | Aligner 차이 영향 |

---

## 3. Input Files

| Label | Path | Size | Format |
|---|---|---|---|
| ec2_cpu | `s3://.../results/gatk/SRR6063611/SRR6063611.g.vcf.gz` | ~7.3 GiB | compressed gVCF |
| omics_bwamem2 | `s3://.../omics-output/6185205/out/gvcf/...` | ~7.3 GiB | compressed gVCF |
| omics_bwa | `s3://.../omics-output/6503897/out/gvcf/...` | ~7.3 GiB | compressed gVCF |
| pb_gpu | `s3://.../output/parabricks-batch/SRR6063611/SRR6063611.g.vcf` | 53.2 GiB | **uncompressed** gVCF |

---

## 4. Execution Steps

### Step 1: Setup + Download (~15 min)

```bash
mkdir -p ~/benchmarking/{gvcf,vcf,concordance/{COMP-A,COMP-B,COMP-C},stats,logs}
```

- `aws s3 cp`로 4개 gVCF + tbi 다운로드
- Reference FASTA/FAI/DICT 다운로드 (이미 로컬에 있으면 생략)

### Step 2: Parabricks gVCF 압축 (~25 min)

```bash
bgzip -@ 8 pb_gpu.g.vcf      # → ~6.8 GiB compressed
tabix -p vcf pb_gpu.g.vcf.gz
```

### Step 3: gVCF → Variant-only VCF 변환 (~20 min)

3개 주요 염색체만 추출 (genome의 ~93%):
- NC_035107.1 (chr 1)
- NC_035108.1 (chr 2)  
- NC_035109.1 (chr 3)

```bash
CHROMS="NC_035107.1,NC_035108.1,NC_035109.1"

# gVCF에서 variant records만 추출 (<NON_REF> reference blocks 제거)
bcftools view -r ${CHROMS} -e 'ALT="<NON_REF>"' --genotype ^hom-ref input.g.vcf.gz \
  | bcftools view -v snps,indels -Oz -o output.vcf.gz
tabix -p vcf output.vcf.gz
```

### Step 4: Variant Normalization (~15 min)

```bash
bcftools norm -m -any -f AaegL5.fasta --check-ref w input.vcf.gz -Oz -o output.norm.vcf.gz
tabix -p vcf output.norm.vcf.gz
```

- Left-align + multi-allelic decompose
- `--check-ref w`로 REF mismatch 경고 확인

### Step 5: bcftools isec — Site-Level Concordance (~15 min)

```bash
# COMP-A: Parabricks GPU vs EC2 CPU
bcftools isec -p concordance/COMP-A/ ec2_cpu.norm.vcf.gz pb_gpu.norm.vcf.gz

# COMP-B: HealthOmics BWA-mem2 vs EC2 CPU
bcftools isec -p concordance/COMP-B/ ec2_cpu.norm.vcf.gz omics_bwamem2.norm.vcf.gz

# COMP-C: HealthOmics BWA vs HealthOmics BWA-mem2
bcftools isec -p concordance/COMP-C/ omics_bwamem2.norm.vcf.gz omics_bwa.norm.vcf.gz
```

출력 구조:
- `0000.vcf` — baseline-only (FN)
- `0001.vcf` — query-only (FP)
- `0002.vcf` — shared, baseline alleles (TP baseline)
- `0003.vcf` — shared, query alleles (TP query)

SNV/indel 별도 카운트.

### Step 6: Metrics 계산 (~5 min)

```
Recall    = Shared / (Shared + Baseline-only)
Precision = Shared / (Shared + Query-only)
F1        = 2 × Precision × Recall / (Precision + Recall)
```

Python 스크립트로 전체 결과 테이블 생성.

### Step 7: bcftools stats — QC Metrics (~15 min)

```bash
bcftools stats input.norm.vcf.gz > stats/label.stats.txt
```

4개 VCF 모두 실행. 비교 항목:
- 전체 SNV / indel count
- Ti/Tv ratio
- Indel size distribution

### Step 8: Genotype Concordance — COMP-A (~5 min)

```bash
bcftools gtcheck -g ec2_cpu.norm.vcf.gz pb_gpu.norm.vcf.gz > stats/COMP-A.gtcheck.txt
```

Shared sites에서 genotype (0/1 vs 1/1 등) 일치 여부 확인.

### Step 9 (Optional): hap.py (~30-60 min)

```bash
docker run -v ~/benchmarking:/data pkrusche/hap.py:v0.3.15 \
  /opt/hap.py/bin/hap.py \
  /data/vcf/ec2_cpu.norm.vcf.gz \
  /data/vcf/pb_gpu.norm.vcf.gz \
  -r /data/ref/AaegL5.fasta \
  -f /data/ref/three_chroms.bed \
  --engine vcfeval \
  -o /data/concordance/happy_COMP-A
```

- Haplotype-aware comparison (bcftools isec보다 정교)
- Samarakoon et al. Figure 5C/D와 직접 비교 가능한 F1 출력
- `--engine vcfeval` (논문과 동일)

---

## 5. Success Criteria

논문 Figure 5C/D 기반:

| Metric | PASS | WARN | 근거 |
|---|---|---|---|
| COMP-A SNV F1 | ≥ 0.990 | 0.975–0.990 | Paper: all samples > 0.975, median ~0.995 |
| COMP-A Indel F1 | ≥ 0.975 | 0.950–0.975 | Paper: wider spread, mostly > 0.975 |
| COMP-B SNV F1 | ≥ 0.985 | — | Same HC engine, different platform |
| COMP-C SNV F1 | ≥ 0.970 | — | Different aligner (BWA vs BWA-mem2) |
| Ti/Tv 차이 | ≤ 0.05 | 0.05–0.10 | 생물학적 일관성 |
| Genotype match (COMP-A shared sites) | ≥ 99.9% | — | — |

---

## 6. Technical Considerations

1. **BQSR 대칭**: 4개 파이프라인 모두 BQSR 미수행 → comparable
2. **FastP trimming 비대칭**: CPU pipelines = FastP trimming 후 alignment, Parabricks = raw FASTQ 직접 입력 (soft-clipping으로 처리). 이 차이가 concordance에 미치는 영향 문서화 필요
3. **Parabricks 버전**: 논문 4.3.0-1, 우리 프로젝트 4.3.1-1 — patch version, HC 핵심 로직 변경 없음
4. **Scaffold 제외**: 2,307 scaffolds 제외하고 3개 chromosomes만 분석 (genome의 ~93%)
5. **Uncompressed gVCF**: Parabricks 출력 53.2 GiB를 bgzip 압축 필요 (Step 2)

---

## 7. Resource Estimates

| Item | 값 |
|---|---|
| Disk peak | ~115 GiB (bgzip 전 Parabricks gVCF 포함) |
| Disk steady state | ~36 GiB (압축 후) |
| Available disk | 506 GiB |
| Core analysis runtime (Steps 1-8) | ~115 min |
| Optional hap.py (Step 9) | +30-60 min |
| 실행 호스트 | EC2 i-0b0068e92b2060948 (r5.4xlarge, 16 vCPU, 128 GiB RAM) |

---

## 8. Output Artifacts

| Output | 위치 |
|---|---|
| bcftools isec 결과 | `~/benchmarking/concordance/COMP-{A,B,C}/` |
| bcftools stats | `~/benchmarking/stats/*.stats.txt` |
| Genotype concordance | `~/benchmarking/stats/COMP-A.gtcheck.txt` |
| hap.py 결과 (optional) | `~/benchmarking/concordance/happy_COMP-A.*` |

### 문서 업데이트 대상

- `test-results.md` — concordance 결과 섹션 추가
- `healthomics-performance-report.md` — concordance 요약 추가
- `workflows/parabricks/README.md` — concordance 결과 반영

---

## 9. Verification Checklist

- [ ] 4개 VCF의 variant count가 합리적 범위 (수백만 SNV, 수십만 indel)
- [ ] Ti/Tv ratio가 ~1.8–2.2 범위
- [ ] COMP-A SNV F1 ≥ 0.990 (논문 Figure 5C 기준)
- [ ] COMP-A Indel F1 ≥ 0.975 (논문 Figure 5D 기준)
- [ ] bcftools isec 출력의 0002/0003 파일 record count 일치 (정상 동작 확인)
- [ ] Genotype match rate ≥ 99.9% (COMP-A shared sites)
