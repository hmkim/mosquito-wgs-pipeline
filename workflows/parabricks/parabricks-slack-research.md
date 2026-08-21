# Slack Parabricks 관련 조사 내용

> 조사일: 2026-04-24

## 1. BWA-mem2 vs Parabricks 비교 테스트 (2026-04-23, DM)

- BWA-mem2를 AI 추천으로 테스트했으나, AVX-512 지원이 있어야만 성능 이점이 발생
- HealthOmics는 SSE로 fallback되어 **5.4x 성능 저하** 발생
- 표준 BWA (v0.7.x)와 Parabricks를 추가 테스트하여 HealthOmics에 최적 솔루션을 찾을 계획

## 2. Parabricks Somatic Mutect2 OOM 이슈 (2026-04-08, #aws-healthomics-interest)

- 고객이 WGS 분석(normal + tumor, 162.6GB)을 **NVIDIA Parabricks Somatic Mutect2 WGS for up to 50X** Ready2Run 워크플로우로 실행
- "ran out of memory" 에러 반복 발생 (Max input 192GiB > 실제 162.6GB인데도 실패)
- Margo McDowall(margomcd)이 support case 또는 internal ticket 생성 요청
- CTI: `AWS > Omics > workflows-support`
- 티켓: D427060504

## 3. Parabricks v3.8 on AWS Batch 배포 이슈 (2025-09, #aws-batch-interest)

가장 상세한 스레드. Joe Bauer(joebau)와 Angel Pizarro(pizarroa) 간 논의.

### 핵심 원인
- **v3.8**: NVIDIA가 자체적으로 컨테이너로 래핑 → Batch에서 Docker 이미지로 호출 시 **Docker-in-Docker** 구조 발생
- **v4.x**: 이 구조가 변경되어 문제 없음

### 해결 방안
- Batch에서 Parabricks 컨테이너를 직접 호출 가능
- Docker-in-Docker가 필요하면 **privileged mode** 활성화 필요
  - [TaskContainerProperties - privileged](https://docs.aws.amazon.com/batch/latest/APIReference/API_TaskContainerProperties.html#Batch-Type-TaskContainerProperties-privileged)

### Batch Job Definition 예시 (v4.5.1-1)

```json
{
  "jobDefinitionName": "clara-parabricks-fq2bam",
  "type": "container",
  "containerProperties": {
    "image": "nvcr.io/nvidia/clara/clara-parabricks:4.5.1-1",
    "vcpus": 4,
    "memory": 8192,
    "resourceRequirements": [
      { "type": "GPU", "value": "1" }
    ],
    "mountPoints": [
      { "sourceVolume": "workdir", "containerPath": "/workdir", "readOnly": false },
      { "sourceVolume": "outputdir", "containerPath": "/outputdir", "readOnly": false }
    ],
    "volumes": [
      { "name": "workdir", "host": { "sourcePath": "/mnt/efs/workdir" } },
      { "name": "outputdir", "host": { "sourcePath": "/mnt/efs/outputdir" } }
    ],
    "jobRoleArn": "arn:aws:iam::ACCOUNT:role/BatchJobRole",
    "executionRoleArn": "arn:aws:iam::ACCOUNT:role/BatchExecutionRole"
  },
  "retryStrategy": { "attempts": 1 },
  "timeout": { "attemptDurationSeconds": 3600 }
}
```

### Submit Job 예시

```bash
aws batch submit-job \
  --job-name "fq2bam-job" \
  --job-queue "gpu-queue" \
  --job-definition "clara-parabricks-fq2bam" \
  --parameters '{
    "command": "pbrun,fq2bam,--ref,/workdir/parabricks_sample/Ref/Homo_sapiens_assembly38.fasta,--in-fq,/workdir/parabricks_sample/Data/sample_1.fq.gz,/workdir/parabricks_sample/Data/sample_2.fq.gz,--out-bam,/outputdir/fq2bam_output.bam"
  }'
```

### 스토리지 참고
- 예시는 EFS host mount 기준
- FSx, Weka, Mountpoint 등 다른 shared filesystem도 사용 가능

## 4. GPU 가속 트렌드 (2025-04, #trainium-interest)

- 유전체 분석은 대부분 CPU에서 실행되지만, NVIDIA Parabricks 등이 GPU 가속 분야에서 발전 중

## 5. NYU Langone Health 사례 (2025-08, #semiconductor-news)

- NYU Langone Health의 deciphEHR 프로그램이 NVIDIA Parabricks 활용
- Alignment **5x+** 속도 향상
- Variant calling **10x+** 속도 향상
