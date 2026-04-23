#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

/*
 * NEA/EHI RADseq Pipeline — based on nf-core/radseq
 * Target: Aedes aegypti (AaegL5 reference) or de novo pseudoreference
 * Platform: AWS HealthOmics (Nextflow engine)
 * Samples: 600 samples × 15 batches
 */

// ============================================================
// Parameters
// ============================================================
params.reads         = "s3://nea-ehi-poc-data-*/raw/mosquito-radseq/*_{R1,R2}.fastq.gz"
params.reference     = "s3://nea-ehi-poc-data-*/reference/mosquito/AaegL5/AaegL5.fasta"
params.outdir        = "s3://nea-ehi-poc-data-*/results/radseq"
params.use_denovo    = false     // Set true for de novo pseudoreference assembly
params.min_quality   = 20
params.min_length    = 50

// ============================================================
// Channels
// ============================================================
Channel
    .fromFilePairs(params.reads, checkIfExists: true)
    .set { read_pairs_ch }

if (!params.use_denovo) {
    Channel.fromPath(params.reference, checkIfExists: true).set { reference_ch }
}

// ============================================================
// Processes
// ============================================================

process FASTQC {
    tag "${sample_id}"
    publishDir "${params.outdir}/qc/fastqc", mode: 'copy'

    input:
    tuple val(sample_id), path(reads)

    output:
    path("*.html"), emit: html
    path("*.zip"),  emit: zip

    script:
    """
    fastqc --threads 2 ${reads}
    """
}

process FASTP {
    tag "${sample_id}"
    publishDir "${params.outdir}/qc/fastp", mode: 'copy'

    input:
    tuple val(sample_id), path(reads)

    output:
    tuple val(sample_id), path("${sample_id}_trimmed_{R1,R2}.fastq.gz"), emit: trimmed
    path("${sample_id}_fastp.html"), emit: report
    path("${sample_id}_fastp.json"), emit: json

    script:
    """
    fastp \
        --in1 ${reads[0]} \
        --in2 ${reads[1]} \
        --out1 ${sample_id}_trimmed_R1.fastq.gz \
        --out2 ${sample_id}_trimmed_R2.fastq.gz \
        --html ${sample_id}_fastp.html \
        --json ${sample_id}_fastp.json \
        --qualified_quality_phred ${params.min_quality} \
        --length_required ${params.min_length} \
        --thread 4
    """
}

// De novo pseudoreference assembly (optional)
process CDHIT_CLUSTER {
    tag "denovo"
    publishDir "${params.outdir}/denovo", mode: 'copy'

    when:
    params.use_denovo

    input:
    path(all_reads)

    output:
    path("clustered.fasta"), emit: clusters

    script:
    """
    # Merge all R1 reads for clustering
    zcat ${all_reads} | head -1000000 > sample_reads.fasta
    cd-hit-est \
        -i sample_reads.fasta \
        -o clustered.fasta \
        -c 0.90 \
        -n 8 \
        -T 8 \
        -M 16000
    """
}

process RAINBOW_ASSEMBLY {
    tag "denovo"
    publishDir "${params.outdir}/denovo", mode: 'copy'

    when:
    params.use_denovo

    input:
    path(clusters)

    output:
    path("pseudoreference.fasta"), emit: reference

    script:
    """
    rainbow div -i ${clusters} -o rainbow_div.out
    rainbow merge -o rainbow_merge.out -a -i rainbow_div.out
    rainbow build -o pseudoreference.fasta -i rainbow_merge.out
    """
}

process BWA_INDEX {
    tag "index"

    input:
    path(reference)

    output:
    tuple path(reference), path("${reference}.*"), emit: indexed

    script:
    """
    bwa-mem2 index ${reference}
    samtools faidx ${reference}
    """
}

process BWA_ALIGN {
    tag "${sample_id}"
    cpus 8
    memory '16 GB'

    input:
    tuple val(sample_id), path(reads)
    tuple path(reference), path(index_files)

    output:
    tuple val(sample_id), path("${sample_id}.bam"), emit: bam

    script:
    """
    bwa-mem2 mem \
        -t ${task.cpus} \
        -R "@RG\\tID:${sample_id}\\tSM:${sample_id}\\tPL:ILLUMINA\\tLB:radseq" \
        ${reference} \
        ${reads[0]} ${reads[1]} \
    | samtools view -bS - > ${sample_id}.bam
    """
}

process UMI_DEDUP {
    tag "${sample_id}"

    input:
    tuple val(sample_id), path(bam)

    output:
    tuple val(sample_id), path("${sample_id}.dedup.bam"), emit: deduped

    script:
    """
    samtools sort -o ${sample_id}.sorted.bam ${bam}
    samtools index ${sample_id}.sorted.bam
    umi_tools dedup \
        -I ${sample_id}.sorted.bam \
        -S ${sample_id}.dedup.bam \
        --output-stats=${sample_id}_dedup_stats
    """
}

process SAMTOOLS_MERGE_INDEX {
    tag "${sample_id}"

    input:
    tuple val(sample_id), path(bam)

    output:
    tuple val(sample_id), path("${sample_id}.final.bam"), path("${sample_id}.final.bam.bai"), emit: indexed_bam

    script:
    """
    samtools sort -@ 4 -o ${sample_id}.final.bam ${bam}
    samtools index ${sample_id}.final.bam
    """
}

process BEDTOOLS_INTERVALS {
    tag "${sample_id}"

    input:
    tuple val(sample_id), path(bam), path(bai)

    output:
    tuple val(sample_id), path("${sample_id}.intervals.bed"), emit: intervals

    script:
    """
    bedtools bamtobed -i ${bam} | \
    bedtools merge -i - | \
    bedtools sort -i - > ${sample_id}.intervals.bed
    """
}

process FREEBAYES {
    tag "${sample_id}"
    cpus 4
    memory '8 GB'
    publishDir "${params.outdir}/vcf/per_sample", mode: 'copy'

    input:
    tuple val(sample_id), path(bam), path(bai)
    tuple val(sample_id2), path(intervals)
    tuple path(reference), path(index_files)

    output:
    tuple val(sample_id), path("${sample_id}.vcf.gz"), emit: vcf

    script:
    """
    freebayes \
        -f ${reference} \
        -t ${intervals} \
        --min-mapping-quality 20 \
        --min-base-quality 20 \
        --min-coverage 5 \
        ${bam} \
    | bcftools sort -Oz -o ${sample_id}.vcf.gz

    tabix -p vcf ${sample_id}.vcf.gz
    """
}

process BCFTOOLS_MERGE {
    tag "merge"
    publishDir "${params.outdir}/vcf", mode: 'copy'

    input:
    path(vcf_files)

    output:
    path("cohort.vcf.gz"),     emit: vcf
    path("cohort.vcf.gz.tbi"), emit: idx

    script:
    def vcf_list = vcf_files.collect { it.name }.join(' ')
    """
    # Index all VCFs
    for f in ${vcf_list}; do
        tabix -p vcf \$f 2>/dev/null || true
    done

    bcftools merge \
        ${vcf_list} \
        -Oz -o cohort.merged.vcf.gz

    bcftools sort \
        cohort.merged.vcf.gz \
        -Oz -o cohort.vcf.gz

    tabix -p vcf cohort.vcf.gz
    """
}

process MULTIQC {
    tag "multiqc"
    publishDir "${params.outdir}/qc", mode: 'copy'

    input:
    path(fastqc_zips)
    path(fastp_jsons)

    output:
    path("multiqc_report.html"), emit: report
    path("multiqc_data"),        emit: data

    script:
    """
    multiqc . --force
    """
}

// ============================================================
// Workflow
// ============================================================
workflow {
    // QC
    FASTQC(read_pairs_ch)
    FASTP(read_pairs_ch)

    // Reference: either provided or de novo assembly
    if (params.use_denovo) {
        all_r1 = FASTP.out.trimmed.map { id, reads -> reads[0] }.collect()
        CDHIT_CLUSTER(all_r1)
        RAINBOW_ASSEMBLY(CDHIT_CLUSTER.out.clusters)
        BWA_INDEX(RAINBOW_ASSEMBLY.out.reference)
    } else {
        BWA_INDEX(reference_ch)
    }

    // Alignment
    BWA_ALIGN(FASTP.out.trimmed, BWA_INDEX.out.indexed)

    // Deduplication
    UMI_DEDUP(BWA_ALIGN.out.bam)

    // Sort & Index
    SAMTOOLS_MERGE_INDEX(UMI_DEDUP.out.deduped)

    // Interval construction
    BEDTOOLS_INTERVALS(SAMTOOLS_MERGE_INDEX.out.indexed_bam)

    // Variant calling
    FREEBAYES(
        SAMTOOLS_MERGE_INDEX.out.indexed_bam,
        BEDTOOLS_INTERVALS.out.intervals,
        BWA_INDEX.out.indexed
    )

    // Merge all sample VCFs
    all_vcfs = FREEBAYES.out.vcf.map { id, vcf -> vcf }.collect()
    BCFTOOLS_MERGE(all_vcfs)

    // MultiQC
    MULTIQC(
        FASTQC.out.zip.collect(),
        FASTP.out.json.collect()
    )
}
