FROM broadinstitute/gatk:4.5.0.0

LABEL maintainer="NEA/EHI POC Team"
LABEL description="GATK pipeline container with BWA v0.7.x for mosquito WGS (HealthOmics-optimized)"

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    bzip2 \
    zlib1g-dev \
    libbz2-dev \
    liblzma-dev \
    libcurl4-openssl-dev \
    make \
    gcc \
    git \
    && rm -rf /var/lib/apt/lists/*

# BWA v0.7.19 (original) — minimal SIMD dependency, stable across CPU architectures
RUN git clone --depth 1 --branch v0.7.19 https://github.com/lh3/bwa.git /tmp/bwa \
    && cd /tmp/bwa && make -j4 \
    && cp bwa /usr/local/bin/bwa \
    && rm -rf /tmp/bwa

# FastQC 0.12.1
RUN wget -qO /tmp/fastqc.zip https://www.bioinformatics.babraham.ac.uk/projects/fastqc/fastqc_v0.12.1.zip \
    && unzip /tmp/fastqc.zip -d /opt/ \
    && chmod +x /opt/FastQC/fastqc \
    && ln -s /opt/FastQC/fastqc /usr/local/bin/fastqc \
    && rm /tmp/fastqc.zip

# FastP (latest binary)
RUN wget -qO /usr/local/bin/fastp http://opengene.org/fastp/fastp \
    && chmod +x /usr/local/bin/fastp

# BCFtools 1.20
RUN wget -qO- https://github.com/samtools/bcftools/releases/download/1.20/bcftools-1.20.tar.bz2 \
    | tar -xjf - -C /tmp \
    && cd /tmp/bcftools-1.20 && make -j4 && make install \
    && rm -rf /tmp/bcftools-1.20

WORKDIR /data
