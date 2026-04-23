FROM ubuntu:22.04

LABEL maintainer="NEA/EHI POC Team"
LABEL description="RADseq pipeline container — BWA-mem2, FreeBayes, UMI-tools, BEDtools, CD-HIT, Rainbow"

ENV DEBIAN_FRONTEND=noninteractive

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget curl bzip2 unzip \
    build-essential cmake \
    zlib1g-dev liblzma-dev libbz2-dev libncurses5-dev libcurl4-openssl-dev \
    python3 python3-pip \
    default-jre \
    && rm -rf /var/lib/apt/lists/*

# SAMtools 1.20
RUN wget -qO- https://github.com/samtools/samtools/releases/download/1.20/samtools-1.20.tar.bz2 \
    | tar -xjf - -C /tmp \
    && cd /tmp/samtools-1.20 && ./configure && make -j4 && make install \
    && rm -rf /tmp/samtools-1.20

# HTSlib 1.20 (tabix)
RUN wget -qO- https://github.com/samtools/htslib/releases/download/1.20/htslib-1.20.tar.bz2 \
    | tar -xjf - -C /tmp \
    && cd /tmp/htslib-1.20 && ./configure && make -j4 && make install \
    && rm -rf /tmp/htslib-1.20

# BCFtools 1.20
RUN wget -qO- https://github.com/samtools/bcftools/releases/download/1.20/bcftools-1.20.tar.bz2 \
    | tar -xjf - -C /tmp \
    && cd /tmp/bcftools-1.20 && make -j4 && make install \
    && rm -rf /tmp/bcftools-1.20

# BWA-mem2
RUN wget -qO- https://github.com/bwa-mem2/bwa-mem2/releases/download/v2.2.1/bwa-mem2-2.2.1_x64-linux.tar.bz2 \
    | tar -xjf - -C /opt/ \
    && ln -s /opt/bwa-mem2-2.2.1_x64-linux/bwa-mem2 /usr/local/bin/bwa-mem2

# FreeBayes
RUN wget -qO /usr/local/bin/freebayes https://github.com/freebayes/freebayes/releases/download/v1.3.7/freebayes-1.3.7-linux-amd64-static \
    && chmod +x /usr/local/bin/freebayes

# BEDtools
RUN wget -qO- https://github.com/arq5x/bedtools2/releases/download/v2.31.1/bedtools-2.31.1.tar.gz \
    | tar -xzf - -C /tmp \
    && cd /tmp/bedtools2 && make -j4 && cp bin/* /usr/local/bin/ \
    && rm -rf /tmp/bedtools2

# CD-HIT-est
RUN wget -qO- https://github.com/weizhongli/cdhit/releases/download/V4.8.1/cd-hit-v4.8.1-2019-0228.tar.gz \
    | tar -xzf - -C /tmp \
    && cd /tmp/cd-hit-v4.8.1-2019-0228 && make -j4 && cp cd-hit-est /usr/local/bin/ \
    && rm -rf /tmp/cd-hit-v4.8.1-2019-0228

# Rainbow
RUN wget -qO- https://sourceforge.net/projects/bio-rainbow/files/rainbow_2.0.4.tar.gz/download \
    | tar -xzf - -C /tmp \
    && cd /tmp/rainbow_2.0.4 && make && cp rainbow /usr/local/bin/ \
    && rm -rf /tmp/rainbow_2.0.4

# UMI-tools
RUN pip3 install --no-cache-dir umi_tools==1.1.5

# FastQC
RUN wget -qO /tmp/fastqc.zip https://www.bioinformatics.babraham.ac.uk/projects/fastqc/fastqc_v0.12.1.zip \
    && unzip /tmp/fastqc.zip -d /opt/ \
    && chmod +x /opt/FastQC/fastqc \
    && ln -s /opt/FastQC/fastqc /usr/local/bin/fastqc \
    && rm /tmp/fastqc.zip

# FastP
RUN wget -qO /usr/local/bin/fastp http://opengene.org/fastp/fastp \
    && chmod +x /usr/local/bin/fastp

# MultiQC
RUN pip3 install --no-cache-dir multiqc==1.22

WORKDIR /data
