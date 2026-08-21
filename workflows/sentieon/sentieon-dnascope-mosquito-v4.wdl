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

    File?  bwa_model
    File?  dnascope_model
    File?  dnascope_model_so

    String sentieon_license
    String sentieon_docker

    Boolean output_cram = true
    Boolean emit_gvcf = true

    String bwa_xargs = ""
    String bwa_karg = "10000000"
    String sort_xargs = "--bam_compression 1"
    String dedup_xargs = "--cram_write_options version=3.0,compressor=rans"

    Int    cpu = 32
    String memory = "64 GiB"
  }

  call SentieonLicenseCheck {
    input:
      sentieon_license = sentieon_license,
      sentieon_docker  = sentieon_docker
  }

  call SentieonGermline {
    input:
      fastq_r1           = fastq_r1,
      fastq_r2           = fastq_r2,
      sample_id          = sample_id,
      read_group         = read_group,
      reference_fasta    = reference_fasta,
      reference_fasta_fai = reference_fasta_fai,
      reference_dict     = reference_dict,
      reference_bwt      = reference_bwt,
      reference_sa       = reference_sa,
      reference_ann      = reference_ann,
      reference_amb      = reference_amb,
      reference_pac      = reference_pac,
      bwa_model          = bwa_model,
      dnascope_model     = dnascope_model,
      dnascope_model_so  = dnascope_model_so,
      sentieon_license   = sentieon_license,
      sentieon_docker    = sentieon_docker,
      license_ok         = SentieonLicenseCheck.license_ok,
      output_cram        = output_cram,
      emit_gvcf          = emit_gvcf,
      bwa_xargs          = bwa_xargs,
      bwa_karg           = bwa_karg,
      sort_xargs         = sort_xargs,
      dedup_xargs        = dedup_xargs,
      cpu                = cpu,
      memory             = memory
  }

  output {
    File  vcf            = SentieonGermline.vcf
    File  vcf_idx        = SentieonGermline.vcf_idx
    File? output_aln     = SentieonGermline.output_aln
    File? output_aln_idx = SentieonGermline.output_aln_idx
    File  dedup_metrics  = SentieonGermline.dedup_metrics
    File? mq_metrics     = SentieonGermline.mq_metrics
    File? qd_metrics     = SentieonGermline.qd_metrics
    File? gc_summary     = SentieonGermline.gc_summary
    File? gc_metrics     = SentieonGermline.gc_metrics
    File? as_metrics     = SentieonGermline.as_metrics
    File? is_metrics     = SentieonGermline.is_metrics
  }
}


task SentieonLicenseCheck {
  input {
    String sentieon_license
    String sentieon_docker
  }

  command <<<
    set -euo pipefail
    export SENTIEON_LICENSE="~{sentieon_license}"

    sentieon licclnt ping && echo "Ping is OK"
    sentieon licclnt query DNAscope
    echo "License OK" > license_ok.txt
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


task SentieonGermline {
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

    File?  bwa_model
    File?  dnascope_model
    File?  dnascope_model_so

    String sentieon_license
    String sentieon_docker
    File   license_ok

    Boolean output_cram
    Boolean emit_gvcf

    String bwa_xargs
    String bwa_karg
    String sort_xargs
    String dedup_xargs

    Int    cpu
    String memory
  }

  String vcf_ext = if emit_gvcf then "g.vcf.gz" else "vcf.gz"

  command <<<
    set -euo pipefail
    export SENTIEON_LICENSE="~{sentieon_license}"

    # --- Setup reference ---
    REF_DIR=/tmp/ref
    mkdir -p $REF_DIR
    REF_BASE=$(basename ~{reference_fasta})
    FASTA_STEM=$(echo $REF_BASE | sed 's/\.[^.]*$//')

    ln -s ~{reference_fasta}     $REF_DIR/$REF_BASE
    ln -s ~{reference_fasta_fai} $REF_DIR/$REF_BASE.fai
    ln -s ~{reference_bwt}       $REF_DIR/$REF_BASE.bwt
    ln -s ~{reference_sa}        $REF_DIR/$REF_BASE.sa
    ln -s ~{reference_ann}       $REF_DIR/$REF_BASE.ann
    ln -s ~{reference_amb}       $REF_DIR/$REF_BASE.amb
    ln -s ~{reference_pac}       $REF_DIR/$REF_BASE.pac
    ln -s ~{reference_dict}      $REF_DIR/$FASTA_STEM.dict

    REF=$REF_DIR/$REF_BASE

    # --- NUMA configuration ---
    numa_nodes=$(lscpu | grep "NUMA node(s):" | sed 's/^NUMA node.* //')
    numa_cpulist=()
    for i in $(seq 1 "$numa_nodes"); do
      i=$((i - 1))
      numa_cpulist+=($(lscpu | grep "NUMA node${i} CPU" | sed 's/^NUMA.* //'))
    done

    nt=$(nproc)
    n_threads=$((nt / numa_nodes))

    # --- BWA model setup ---
    bwa_model_arg=""
    bwa_model="~{default='' bwa_model}"
    if [[ -n "$bwa_model" ]]; then
      bwa_model_arg="-x $(realpath "$bwa_model")"
    fi

    # --- Alignment (NUMA-aware, igzip, pipe buffer optimization) ---
    echo "=== Starting BWA alignment ($nt threads, $numa_nodes NUMA nodes) ==="
    alignment_output=()

    for j in $(seq 1 "$numa_nodes"); do
      j=$((j - 1))
      cpulist="${numa_cpulist[$j]}"

      perl -MFcntl -e 'fcntl(STDOUT, 1031, 268435456)';
      taskset -c "$cpulist" sentieon bwa mem \
        -R "~{read_group}" \
        ~{bwa_xargs} -K ~{bwa_karg} -t $n_threads \
        $bwa_model_arg \
        "$REF" \
        <(perl -MFcntl -e 'fcntl(STDOUT, 1031, 268435456)'; \
          sentieon fqidx extract -F "$j"/"$numa_nodes" -K ~{bwa_karg} \
          <(perl -MFcntl -e 'fcntl(STDOUT, 1031, 268435456)'; igzip -dc ~{fastq_r1}) \
          <(perl -MFcntl -e 'fcntl(STDOUT, 1031, 268435456)'; igzip -dc ~{fastq_r2})) | \
        taskset -c "$cpulist" sentieon util sort -t $n_threads --sam2bam \
        -o "sorted_${j}.bam" -i - ~{sort_xargs} &
      alignment_output+=("sorted_${j}.bam")
    done
    wait
    echo "Alignment completed."

    # Build input BAM string
    bam_str=()
    for f in "${alignment_output[@]}"; do
      bam_str+=("-i" "$f")
    done

    # --- LocusCollector + QC metrics ---
    echo "=== Running LocusCollector + QC ==="
    sentieon driver "${bam_str[@]}" -r "$REF" \
      --algo LocusCollector "~{sample_id}_score.txt.gz" \
      --algo MeanQualityByCycle "~{sample_id}_mq_metrics.txt" \
      --algo QualDistribution "~{sample_id}_qd_metrics.txt" \
      --algo GCBias --summary "~{sample_id}_gc_summary.txt" "~{sample_id}_gc_metrics.txt" \
      --algo AlignmentStat --adapter_seq '' "~{sample_id}_aln_metrics.txt" \
      --algo InsertSizeMetricAlgo "~{sample_id}_is_metrics.txt"

    # --- Dedup → CRAM ---
    echo "=== Running Dedup ==="
    output_aln="~{sample_id}_aligned.cram"
    sentieon driver "${bam_str[@]}" -r "$REF" \
      --algo Dedup ~{dedup_xargs} \
      --score_info "~{sample_id}_score.txt.gz" \
      --metrics "~{sample_id}_dedup_metrics.txt" \
      "$output_aln"

    # Remove intermediate sorted BAMs
    rm -f "${alignment_output[@]}"
    rm -f ~{sample_id}_score.txt.gz

    # --- DNAscope variant calling ---
    echo "=== Running DNAscope ==="
    dnascope_model="~{default='' dnascope_model}"
    dnascope_model_so="~{default='' dnascope_model_so}"

    model_arg=""
    if [[ -n "$dnascope_model" ]]; then
      model_arg="--model $(realpath "$dnascope_model")"
    fi

    output_vcf="~{sample_id}.~{vcf_ext}"
    sentieon driver -r "$REF" \
      -i "$output_aln" \
      --algo DNAscope \
      ~{true="--emit_mode gvcf" false="" emit_gvcf} \
      $model_arg \
      "$output_vcf"

    # --- DNAModelApply (if model provided) ---
    if [[ -n "$dnascope_model" && -n "$dnascope_model_so" ]]; then
      echo "=== Running DNAModelApply ==="
      MODEL_PATH=$(realpath "$dnascope_model")
      MODEL_DIR=$(dirname "$MODEL_PATH")
      SO_PATH=$(realpath "$dnascope_model_so")

      # Ensure .so is adjacent to model file
      if [[ ! -f "$MODEL_DIR/$(basename "$SO_PATH")" ]]; then
        ln -s "$SO_PATH" "$MODEL_DIR/$(basename "$SO_PATH")"
        echo "Symlinked .so to $MODEL_DIR/"
      fi

      tmp_vcf="~{sample_id}.tmp.~{vcf_ext}"
      mv "$output_vcf" "$tmp_vcf"
      mv "${output_vcf}.tbi" "${tmp_vcf}.tbi"

      sentieon driver -r "$REF" \
        --algo DNAModelApply \
        --model "$MODEL_PATH" \
        -v "$tmp_vcf" \
        "$output_vcf"

      rm -f "$tmp_vcf" "${tmp_vcf}.tbi"
    fi

    # --- Finalize output alignment ---
    if [ "~{output_cram}" = "true" ]; then
      mv "$output_aln" "~{sample_id}.cram"
      if [[ -f "${output_aln}.crai" ]]; then
        mv "${output_aln}.crai" "~{sample_id}.cram.crai"
      else
        sentieon util index "~{sample_id}.cram"
      fi
    else
      samtools view -@ $nt -b -o "~{sample_id}.bam" "$output_aln"
      samtools index "~{sample_id}.bam"
      rm -f "$output_aln" "${output_aln}.crai"
    fi

    echo "=== Pipeline completed ==="
    ls -lh ~{sample_id}.*
  >>>

  runtime {
    docker: sentieon_docker
    cpu:    cpu
    memory: memory
  }

  output {
    File  vcf            = "~{sample_id}.~{vcf_ext}"
    File  vcf_idx        = "~{sample_id}.~{vcf_ext}.tbi"
    File? output_aln     = "~{sample_id}.~{if output_cram then 'cram' else 'bam'}"
    File? output_aln_idx = "~{sample_id}.~{if output_cram then 'cram.crai' else 'bam.bai'}"
    File  dedup_metrics  = "~{sample_id}_dedup_metrics.txt"
    File? mq_metrics     = "~{sample_id}_mq_metrics.txt"
    File? qd_metrics     = "~{sample_id}_qd_metrics.txt"
    File? gc_summary     = "~{sample_id}_gc_summary.txt"
    File? gc_metrics     = "~{sample_id}_gc_metrics.txt"
    File? as_metrics     = "~{sample_id}_aln_metrics.txt"
    File? is_metrics     = "~{sample_id}_is_metrics.txt"
  }
}
