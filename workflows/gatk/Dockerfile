FROM broadinstitute/gatk:4.5.0.0

LABEL maintainer="NEA/EHI POC Team"
LABEL description="GATK pipeline container for mosquito and microbial WGS"

# Install additional tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    bzip2 \
    zlib1g-dev \
    libbz2-dev \
    liblzma-dev \
    libcurl4-openssl-dev \
    make \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Install BWA-mem2
RUN wget -qO- https://github.com/bwa-mem2/bwa-mem2/releases/download/v2.2.1/bwa-mem2-2.2.1_x64-linux.tar.bz2 \
    | tar -xjf - -C /opt/ \
    && ln -s /opt/bwa-mem2-2.2.1_x64-linux/bwa-mem2 /usr/local/bin/bwa-mem2

# Install FastQC
RUN wget -qO /tmp/fastqc.zip https://www.bioinformatics.babraham.ac.uk/projects/fastqc/fastqc_v0.12.1.zip \
    && unzip /tmp/fastqc.zip -d /opt/ \
    && chmod +x /opt/FastQC/fastqc \
    && ln -s /opt/FastQC/fastqc /usr/local/bin/fastqc \
    && rm /tmp/fastqc.zip

# Install FastP
RUN wget -qO /usr/local/bin/fastp http://opengene.org/fastp/fastp \
    && chmod +x /usr/local/bin/fastp

# Install BCFtools and tabix (htslib)
RUN wget -qO- https://github.com/samtools/bcftools/releases/download/1.20/bcftools-1.20.tar.bz2 \
    | tar -xjf - -C /tmp \
    && cd /tmp/bcftools-1.20 && make -j4 && make install \
    && rm -rf /tmp/bcftools-1.20

WORKDIR /data
