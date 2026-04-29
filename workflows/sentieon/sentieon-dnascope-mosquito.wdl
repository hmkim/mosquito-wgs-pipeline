version 1.0

workflow SentieonDNAscopeMosquito {
  input {
    File   fastq_r1
    File   fastq_r2
    String sample_id
    String read_group

    File   reference_fasta
    File   reference_fasta_fai
    File   reference_dict
    File   reference_bwt
    File   reference_sa
    File   reference_ann
    File   reference_amb
    File   reference_pac

    String sentieon_license
    String sentieon_docker

    Boolean output_cram = true
    Boolean emit_gvcf = true
    Boolean run_dnascope = true

    Int    alignment_cpu = 32
    String alignment_memory = "64 GiB"
    Int    calling_cpu = 32
    String calling_memory = "64 GiB"
  }

  call SentieonLicenseCheck {
    input:
      sentieon_license = sentieon_license,
      sentieon_docker  = sentieon_docker,
      run_dnascope     = run_dnascope
  }

  call SentieonAlignment {
    input:
      fastq_r1           = fastq_r1,
      fastq_r2           = fastq_r2,
      sample_id          = sample_id,
      read_group         = read_group,
      reference_fasta    = reference_fasta,
      reference_fasta_fai = reference_fasta_fai,
      reference_bwt      = reference_bwt,
      reference_sa       = reference_sa,
      reference_ann      = reference_ann,
      reference_amb      = reference_amb,
      reference_pac      = reference_pac,
      sentieon_license   = sentieon_license,
      sentieon_docker    = sentieon_docker,
      license_ok         = SentieonLicenseCheck.license_ok,
      cpu                = alignment_cpu,
      memory             = alignment_memory
  }

  call SentieonDedupAndCall {
    input:
      sorted_bam          = SentieonAlignment.sorted_bam,
      sorted_bai          = SentieonAlignment.sorted_bai,
      sample_id           = sample_id,
      reference_fasta     = reference_fasta,
      reference_fasta_fai = reference_fasta_fai,
      reference_dict      = reference_dict,
      sentieon_license    = sentieon_license,
      sentieon_docker     = sentieon_docker,
      output_cram         = output_cram,
      emit_gvcf           = emit_gvcf,
      run_dnascope        = run_dnascope,
      cpu                 = calling_cpu,
      memory              = calling_memory
  }

  output {
    File  vcf               = SentieonDedupAndCall.vcf
    File  vcf_idx           = SentieonDedupAndCall.vcf_idx
    File  output_aln        = SentieonDedupAndCall.output_aln
    File  output_aln_idx    = SentieonDedupAndCall.output_aln_idx
    File  dedup_metrics     = SentieonDedupAndCall.dedup_metrics
    File  sorted_bam        = SentieonAlignment.sorted_bam
    File  sorted_bai        = SentieonAlignment.sorted_bai
  }
}


task SentieonLicenseCheck {
  input {
    String sentieon_license
    String sentieon_docker
    Boolean run_dnascope
  }

  command <<<
    set -euo pipefail
    export SENTIEON_LICENSE="~{sentieon_license}"

    echo "Checking license server connectivity..."
    sentieon licclnt ping
    echo "License ping: OK"

    if [ "~{run_dnascope}" = "true" ]; then
      sentieon licclnt query DNAscope
      echo "DNAscope feature: OK"
    else
      sentieon licclnt query Haplotyper
      echo "Haplotyper feature: OK"
    fi

    echo "license_ok" > license_ok.txt
  >>>

  runtime {
    docker: sentieon_docker
    cpu:    1
    memory: "1 GiB"
  }

  output {
    File license_ok = "license_ok.txt"
  }
}


task SentieonAlignment {
  input {
    File   fastq_r1
    File   fastq_r2
    String sample_id
    String read_group
    File   reference_fasta
    File   reference_fasta_fai
    File   reference_bwt
    File   reference_sa
    File   reference_ann
    File   reference_amb
    File   reference_pac
    String sentieon_license
    String sentieon_docker
    File   license_ok
    Int    cpu
    String memory
  }

  command <<<
    set -euo pipefail
    export SENTIEON_LICENSE="~{sentieon_license}"

    REF_DIR=/tmp/ref
    mkdir -p $REF_DIR
    REF_BASE=$(basename ~{reference_fasta})

    ln -s ~{reference_fasta}     $REF_DIR/$REF_BASE
    ln -s ~{reference_fasta_fai} $REF_DIR/$REF_BASE.fai
    ln -s ~{reference_bwt}       $REF_DIR/$REF_BASE.bwt
    ln -s ~{reference_sa}        $REF_DIR/$REF_BASE.sa
    ln -s ~{reference_ann}       $REF_DIR/$REF_BASE.ann
    ln -s ~{reference_amb}       $REF_DIR/$REF_BASE.amb
    ln -s ~{reference_pac}       $REF_DIR/$REF_BASE.pac

    NPROC=$(nproc)
    echo "Starting BWA alignment with $NPROC threads..."

    sentieon bwa mem \
      -M \
      -R "~{read_group}" \
      -t $NPROC \
      -K 100000000 \
      $REF_DIR/$REF_BASE \
      ~{fastq_r1} ~{fastq_r2} \
    | sentieon util sort \
      --sam2bam \
      --reference $REF_DIR/$REF_BASE \
      -t $NPROC \
      -o ~{sample_id}.sorted.bam \
      -i -

    sentieon util index ~{sample_id}.sorted.bam

    echo "Alignment completed."
    ls -lh ~{sample_id}.sorted.bam*
  >>>

  runtime {
    docker: sentieon_docker
    cpu:    cpu
    memory: memory
  }

  output {
    File sorted_bam = "~{sample_id}.sorted.bam"
    File sorted_bai = "~{sample_id}.sorted.bam.bai"
  }
}


task SentieonDedupAndCall {
  input {
    File   sorted_bam
    File   sorted_bai
    String sample_id
    File   reference_fasta
    File   reference_fasta_fai
    File   reference_dict
    String sentieon_license
    String sentieon_docker
    Boolean output_cram
    Boolean emit_gvcf
    Boolean run_dnascope
    Int    cpu
    String memory
  }

  String vcf_ext = if emit_gvcf then "g.vcf.gz" else "vcf.gz"
  String aln_ext = if output_cram then "cram" else "bam"

  command <<<
    set -euo pipefail
    export SENTIEON_LICENSE="~{sentieon_license}"

    REF_DIR=/tmp/ref
    mkdir -p $REF_DIR
    REF_BASE=$(basename ~{reference_fasta})

    ln -s ~{reference_fasta}     $REF_DIR/$REF_BASE
    ln -s ~{reference_fasta_fai} $REF_DIR/$REF_BASE.fai

    FASTA_STEM=$(echo $REF_BASE | sed 's/\.[^.]*$//')
    ln -s ~{reference_dict} $REF_DIR/$FASTA_STEM.dict

    if [ ! -L "$REF_DIR/$FASTA_STEM.dict" ]; then
      echo "[ERROR] Dict symlink failed: $REF_DIR/$FASTA_STEM.dict"
      exit 1
    fi

    NPROC=$(nproc)

    echo "Running LocusCollector..."
    sentieon driver \
      -t $NPROC \
      -r $REF_DIR/$REF_BASE \
      -i ~{sorted_bam} \
      --algo LocusCollector \
      --fun score_info \
      ~{sample_id}.score.txt

    echo "Running Dedup..."
    sentieon driver \
      -t $NPROC \
      -r $REF_DIR/$REF_BASE \
      -i ~{sorted_bam} \
      --algo Dedup \
      --score_info ~{sample_id}.score.txt \
      --metrics ~{sample_id}.dedup_metrics.txt \
      ~{sample_id}.dedup.bam

    rm -f ~{sample_id}.score.txt

    CALL_ALGO="Haplotyper"
    if [ "~{run_dnascope}" = "true" ]; then
      CALL_ALGO="DNAscope"
    fi

    EMIT_MODE=""
    if [ "~{emit_gvcf}" = "true" ]; then
      EMIT_MODE="--emit_mode gvcf"
    fi

    echo "Running $CALL_ALGO..."
    sentieon driver \
      -t $NPROC \
      -r $REF_DIR/$REF_BASE \
      -i ~{sample_id}.dedup.bam \
      --algo $CALL_ALGO \
      $EMIT_MODE \
      ~{sample_id}.~{vcf_ext}

    if [ "~{output_cram}" = "true" ]; then
      echo "Converting to CRAM..."
      samtools view -@ $NPROC -C -T $REF_DIR/$REF_BASE \
        -o ~{sample_id}.cram ~{sample_id}.dedup.bam
      samtools index -@ $NPROC ~{sample_id}.cram
      rm -f ~{sample_id}.dedup.bam ~{sample_id}.dedup.bam.bai
    else
      mv ~{sample_id}.dedup.bam ~{sample_id}.bam
      mv ~{sample_id}.dedup.bam.bai ~{sample_id}.bam.bai
    fi

    echo "Pipeline completed."
    ls -lh ~{sample_id}.*
  >>>

  runtime {
    docker: sentieon_docker
    cpu:    cpu
    memory: memory
  }

  output {
    File vcf            = "~{sample_id}.~{vcf_ext}"
    File vcf_idx        = "~{sample_id}.~{vcf_ext}.tbi"
    File output_aln     = "~{sample_id}.~{aln_ext}"
    File output_aln_idx = "~{sample_id}.~{aln_ext}.~{if output_cram then 'crai' else 'bai'}"
    File dedup_metrics  = "~{sample_id}.dedup_metrics.txt"
  }
}
