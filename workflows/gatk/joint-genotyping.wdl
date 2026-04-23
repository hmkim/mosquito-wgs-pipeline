version 1.0

## Joint Genotyping Workflow
## Consolidates per-sample gVCFs and performs joint genotyping + filtering
## Platform: AWS HealthOmics
## Reference: Nature Communications 2025 — SNP filtering criteria

workflow JointGenotyping {
  input {
    Array[File] gvcf_files
    Array[File] gvcf_idx_files
    String cohort_name
    File reference_fasta
    File reference_fasta_idx
    File reference_dict
    File intervals_list
    String docker_image = "<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/nea-ehi-gatk:latest"
  }

  call GenomicsDBImport {
    input:
      gvcf_files = gvcf_files,
      gvcf_idx_files = gvcf_idx_files,
      cohort_name = cohort_name,
      reference_fasta = reference_fasta,
      reference_fasta_idx = reference_fasta_idx,
      reference_dict = reference_dict,
      intervals_list = intervals_list,
      docker_image = docker_image
  }

  call GenotypeGVCFs {
    input:
      genomicsdb_tar = GenomicsDBImport.genomicsdb_tar,
      cohort_name = cohort_name,
      reference_fasta = reference_fasta,
      reference_fasta_idx = reference_fasta_idx,
      reference_dict = reference_dict,
      docker_image = docker_image
  }

  call FilterVariants {
    input:
      raw_vcf = GenotypeGVCFs.raw_vcf,
      cohort_name = cohort_name,
      docker_image = docker_image
  }

  output {
    File raw_vcf = GenotypeGVCFs.raw_vcf
    File filtered_vcf = FilterVariants.filtered_vcf
    File filtered_vcf_idx = FilterVariants.filtered_vcf_idx
  }
}

task GenomicsDBImport {
  input {
    Array[File] gvcf_files
    Array[File] gvcf_idx_files
    String cohort_name
    File reference_fasta
    File reference_fasta_idx
    File reference_dict
    File intervals_list
    String docker_image
  }

  command <<<
    # Create sample map from gVCF file paths
    paste \
      <(for f in ~{sep=' ' gvcf_files}; do basename "$f" .g.vcf.gz; done) \
      <(echo '~{sep="\n" gvcf_files}') \
      > sample_map.txt

    gatk GenomicsDBImport \
      --sample-name-map sample_map.txt \
      --genomicsdb-workspace-path genomicsdb_~{cohort_name} \
      --reader-threads 4 \
      --batch-size 50 \
      -R ~{reference_fasta} \
      -L ~{intervals_list}

    # Tar the workspace for portability between tasks
    tar -cf genomicsdb_~{cohort_name}.tar genomicsdb_~{cohort_name}
  >>>

  runtime {
    docker: docker_image
    cpu: 4
    memory: "32 GiB"
  }

  output {
    File genomicsdb_tar = "genomicsdb_~{cohort_name}.tar"
  }
}

task GenotypeGVCFs {
  input {
    File genomicsdb_tar
    String cohort_name
    File reference_fasta
    File reference_fasta_idx
    File reference_dict
    String docker_image
  }

  command <<<
    # Extract GenomicsDB workspace
    tar -xf ~{genomicsdb_tar}

    gatk GenotypeGVCFs \
      -R ~{reference_fasta} \
      -V gendb://genomicsdb_~{cohort_name} \
      -O ~{cohort_name}.raw.vcf.gz
  >>>

  runtime {
    docker: docker_image
    cpu: 4
    memory: "16 GiB"
  }

  output {
    File raw_vcf = "~{cohort_name}.raw.vcf.gz"
  }
}

task FilterVariants {
  input {
    File raw_vcf
    String cohort_name
    String docker_image
  }

  ## Filtering criteria from the reference paper:
  ## Site: QD < 5, FS > 60, ReadPosRankSum < -8
  ## Genotype: GQ > 20, DP >= 10
  command <<<
    bcftools filter \
      -e 'INFO/QD < 5 || INFO/FS > 60 || INFO/ReadPosRankSum < -8' \
      ~{raw_vcf} | \
    bcftools view \
      -i 'FORMAT/GQ > 20 && FORMAT/DP >= 10' \
      -Oz -o ~{cohort_name}.filtered.vcf.gz

    tabix -p vcf ~{cohort_name}.filtered.vcf.gz
  >>>

  runtime {
    docker: docker_image
    cpu: 2
    memory: "8 GiB"
  }

  output {
    File filtered_vcf = "~{cohort_name}.filtered.vcf.gz"
    File filtered_vcf_idx = "~{cohort_name}.filtered.vcf.gz.tbi"
  }
}
