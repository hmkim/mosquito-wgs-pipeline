version 1.0

## GATK Mosquito WGS Pipeline — BWA v0.7.x variant
## Uses original BWA-MEM instead of BWA-mem2 for consistent performance
## on AWS HealthOmics (avoids SIMD instruction set degradation).
## Target: Aedes aegypti (AaegL5 reference genome)
## Platform: AWS HealthOmics / EC2

workflow GatkMosquitoPipeline {
  input {
    File fastq_r1
    File fastq_r2
    String sample_id
    File reference_fasta
    File reference_fasta_idx
    File reference_dict
    # BWA v0.7.x index files (.amb, .ann, .bwt, .pac, .sa)
    File reference_bwt
    File reference_ann
    File reference_amb
    File reference_pac
    File reference_sa
    String docker_image = "<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/nea-ehi-gatk-bwa:latest"
  }

  call FastQC {
    input:
      fastq_r1 = fastq_r1,
      fastq_r2 = fastq_r2,
      sample_id = sample_id,
      docker_image = docker_image
  }

  call FastP {
    input:
      fastq_r1 = fastq_r1,
      fastq_r2 = fastq_r2,
      sample_id = sample_id,
      docker_image = docker_image
  }

  call BwaAlign {
    input:
      trimmed_r1 = FastP.trimmed_r1,
      trimmed_r2 = FastP.trimmed_r2,
      sample_id = sample_id,
      reference_fasta = reference_fasta,
      reference_bwt = reference_bwt,
      reference_ann = reference_ann,
      reference_amb = reference_amb,
      reference_pac = reference_pac,
      reference_sa = reference_sa,
      reference_fasta_idx = reference_fasta_idx,
      docker_image = docker_image
  }

  call SortAndIndex {
    input:
      bam = BwaAlign.aligned_bam,
      sample_id = sample_id,
      docker_image = docker_image
  }

  call MarkDuplicates {
    input:
      sorted_bam = SortAndIndex.sorted_bam,
      sample_id = sample_id,
      docker_image = docker_image
  }

  call HaplotypeCaller {
    input:
      deduped_bam = MarkDuplicates.deduped_bam,
      deduped_bai = MarkDuplicates.deduped_bai,
      sample_id = sample_id,
      reference_fasta = reference_fasta,
      reference_fasta_idx = reference_fasta_idx,
      reference_dict = reference_dict,
      docker_image = docker_image
  }

  output {
    File gvcf = HaplotypeCaller.gvcf
    File gvcf_idx = HaplotypeCaller.gvcf_idx
    File fastqc_r1_html = FastQC.r1_html
    File fastqc_r2_html = FastQC.r2_html
    File fastp_report = FastP.report_html
    File dedup_metrics = MarkDuplicates.metrics
  }
}

task FastQC {
  input {
    File fastq_r1
    File fastq_r2
    String sample_id
    String docker_image
  }

  command <<<
    mkdir -p output
    fastqc ~{fastq_r1} ~{fastq_r2} -o output --threads 2
  >>>

  runtime {
    docker: docker_image
    cpu: 2
    memory: "4 GiB"
  }

  output {
    File r1_html = glob("output/*_R1*fastqc.html")[0]
    File r2_html = glob("output/*_R2*fastqc.html")[0]
  }
}

task FastP {
  input {
    File fastq_r1
    File fastq_r2
    String sample_id
    String docker_image
  }

  command <<<
    fastp \
      --in1 ~{fastq_r1} \
      --in2 ~{fastq_r2} \
      --out1 ~{sample_id}_trimmed_R1.fastq.gz \
      --out2 ~{sample_id}_trimmed_R2.fastq.gz \
      --html ~{sample_id}_fastp.html \
      --json ~{sample_id}_fastp.json \
      --thread 4 \
      --qualified_quality_phred 20 \
      --length_required 50
  >>>

  runtime {
    docker: docker_image
    cpu: 4
    memory: "8 GiB"
  }

  output {
    File trimmed_r1 = "~{sample_id}_trimmed_R1.fastq.gz"
    File trimmed_r2 = "~{sample_id}_trimmed_R2.fastq.gz"
    File report_html = "~{sample_id}_fastp.html"
  }
}

task BwaAlign {
  input {
    File trimmed_r1
    File trimmed_r2
    String sample_id
    File reference_fasta
    File reference_bwt
    File reference_ann
    File reference_amb
    File reference_pac
    File reference_sa
    File reference_fasta_idx
    String docker_image
  }

  command <<<
    # Stage reference files in a writable directory.
    # HealthOmics localizes inputs to read-only paths;
    # BWA expects index files alongside the FASTA.
    REF_DIR=/tmp/ref
    mkdir -p ${REF_DIR}
    REF_BASE=$(basename ~{reference_fasta})

    ln -s ~{reference_fasta} ${REF_DIR}/${REF_BASE}
    ln -s ~{reference_bwt} ${REF_DIR}/${REF_BASE}.bwt
    ln -s ~{reference_ann} ${REF_DIR}/${REF_BASE}.ann
    ln -s ~{reference_amb} ${REF_DIR}/${REF_BASE}.amb
    ln -s ~{reference_pac} ${REF_DIR}/${REF_BASE}.pac
    ln -s ~{reference_sa} ${REF_DIR}/${REF_BASE}.sa
    ln -s ~{reference_fasta_idx} ${REF_DIR}/${REF_BASE}.fai

    bwa mem \
      -t 8 \
      -R "@RG\tID:~{sample_id}\tSM:~{sample_id}\tPL:ILLUMINA\tLB:lib1" \
      ${REF_DIR}/${REF_BASE} \
      ~{trimmed_r1} ~{trimmed_r2} \
    | samtools view -bS - > ~{sample_id}.aligned.bam
  >>>

  runtime {
    docker: docker_image
    cpu: 8
    memory: "32 GiB"
  }

  output {
    File aligned_bam = "~{sample_id}.aligned.bam"
  }
}

task SortAndIndex {
  input {
    File bam
    String sample_id
    String docker_image
  }

  command <<<
    samtools sort -@ 4 -o ~{sample_id}.sorted.bam ~{bam}
    samtools index ~{sample_id}.sorted.bam
  >>>

  runtime {
    docker: docker_image
    cpu: 4
    memory: "16 GiB"
  }

  output {
    File sorted_bam = "~{sample_id}.sorted.bam"
    File sorted_bai = "~{sample_id}.sorted.bam.bai"
  }
}

task MarkDuplicates {
  input {
    File sorted_bam
    String sample_id
    String docker_image
  }

  command <<<
    gatk MarkDuplicates \
      -I ~{sorted_bam} \
      -O ~{sample_id}.dedup.bam \
      -M ~{sample_id}.dedup_metrics.txt \
      --REMOVE_DUPLICATES false \
      --CREATE_INDEX true
  >>>

  runtime {
    docker: docker_image
    cpu: 2
    memory: "32 GiB"
  }

  output {
    File deduped_bam = "~{sample_id}.dedup.bam"
    File deduped_bai = "~{sample_id}.dedup.bai"
    File metrics = "~{sample_id}.dedup_metrics.txt"
  }
}

task HaplotypeCaller {
  input {
    File deduped_bam
    File deduped_bai
    String sample_id
    File reference_fasta
    File reference_fasta_idx
    File reference_dict
    String docker_image
  }

  command <<<
    REF_DIR=/tmp/ref
    mkdir -p ${REF_DIR}
    REF_BASE=$(basename ~{reference_fasta})
    DICT_NAME=$(basename ~{reference_fasta} .fasta).dict

    ln -s ~{reference_fasta} ${REF_DIR}/${REF_BASE}
    ln -s ~{reference_fasta_idx} ${REF_DIR}/${REF_BASE}.fai
    ln -s ~{reference_dict} ${REF_DIR}/${DICT_NAME}

    BAM_DIR=$(dirname ~{deduped_bam})
    ln -sf ~{deduped_bai} ${BAM_DIR}/$(basename ~{deduped_bam} .bam).bai 2>/dev/null || \
      ln -s ~{deduped_bai} $(dirname ~{deduped_bam})/$(basename ~{deduped_bam}).bai 2>/dev/null || true

    gatk HaplotypeCaller \
      -R ${REF_DIR}/${REF_BASE} \
      -I ~{deduped_bam} \
      -O ~{sample_id}.g.vcf.gz \
      -ERC GVCF \
      --min-base-quality-score 20
  >>>

  runtime {
    docker: docker_image
    cpu: 4
    memory: "16 GiB"
  }

  output {
    File gvcf = "~{sample_id}.g.vcf.gz"
    File gvcf_idx = "~{sample_id}.g.vcf.gz.tbi"
  }
}
