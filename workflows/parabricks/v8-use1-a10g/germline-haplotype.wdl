version 1.0

task fq2bam {
    input {
        File inputFASTQ_1
        File inputFASTQ_2
        String sample_id
        File inputRefTarball
        String docker
    }

    String ref = basename(inputRefTarball, ".tar")

    command {
        set -e
        set -x
        set -o pipefail
        mkdir -p tmp_fq2bam && \
        time tar xf ~{inputRefTarball} && \
        time pbrun fq2bam \
            --tmp-dir tmp_fq2bam \
            --in-fq ~{inputFASTQ_1} ~{inputFASTQ_2} \
            "@RG\tID:~{sample_id}\tLB:lib1\tPL:ILLUMINA\tSM:~{sample_id}\tPU:unit1" \
            --ref ~{ref} \
            --out-bam ~{sample_id}.pb.bam \
            --out-duplicate-metrics ~{sample_id}.duplicate_metrics.txt \
            --low-memory
    }

    output {
        File outputBAM = "~{sample_id}.pb.bam"
        File outputBAI = "~{sample_id}.pb.bam.bai"
        File outputDupMetrics = "~{sample_id}.duplicate_metrics.txt"
    }

    runtime {
        docker: docker
        acceleratorType: "nvidia-tesla-a10g"
        acceleratorCount: 4
        cpu: 48
        memory: "192 GiB"
    }
}

task haplotypecaller {
    input {
        File inputBAM
        File inputBAI
        File inputRefTarball
        String sample_id
        String docker
    }

    String localTarball = basename(inputRefTarball)
    String ref = basename(inputRefTarball, ".tar")

    command {
        set -e
        set -x
        set -o pipefail
        mv ~{inputRefTarball} ~{localTarball} && \
        time tar xf ~{localTarball} && \
        time pbrun haplotypecaller \
            --in-bam ~{inputBAM} \
            --ref ~{ref} \
            --out-variants ~{sample_id}.g.vcf \
            --gvcf
    }

    output {
        File outputGVCF = "~{sample_id}.g.vcf"
    }

    runtime {
        docker: docker
        acceleratorType: "nvidia-tesla-a10g"
        acceleratorCount: 4
        cpu: 48
        memory: "192 GiB"
    }
}

workflow ParabricksGermline {
    input {
        File inputFASTQ_1
        File inputFASTQ_2
        File inputRefTarball
        String sample_id
        String pb_version
        String ecr_registry
    }

    String docker = ecr_registry + "/parabricks:" + pb_version

    call fq2bam {
        input:
            inputFASTQ_1 = inputFASTQ_1,
            inputFASTQ_2 = inputFASTQ_2,
            sample_id = sample_id,
            inputRefTarball = inputRefTarball,
            docker = docker
    }

    call haplotypecaller {
        input:
            inputBAM = fq2bam.outputBAM,
            inputBAI = fq2bam.outputBAI,
            inputRefTarball = inputRefTarball,
            sample_id = sample_id,
            docker = docker
    }

    output {
        File outputBAM = fq2bam.outputBAM
        File outputBAI = fq2bam.outputBAI
        File outputDupMetrics = fq2bam.outputDupMetrics
        File outputGVCF = haplotypecaller.outputGVCF
    }

    meta {
        description: "GPU-accelerated germline variant calling using NVIDIA Parabricks on AWS HealthOmics (A10G, us-east-1)"
    }
}
