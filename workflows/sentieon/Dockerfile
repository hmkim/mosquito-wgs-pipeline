FROM amazonlinux:2 AS build

ARG SENTIEON_VERSION=202503.03

RUN yum update -y && yum install -y \
    autoconf automake make gcc gcc-c++ \
    zlib-devel bzip2-devel xz-devel libcurl-devel openssl-devel ncurses-devel \
    wget tar gzip nasm cmake3 git \
    && yum clean all

# samtools 1.16.1
RUN cd /tmp && \
    wget -q https://github.com/samtools/samtools/releases/download/1.16.1/samtools-1.16.1.tar.bz2 && \
    tar -xjf samtools-1.16.1.tar.bz2 && cd samtools-1.16.1 && \
    ./configure --prefix=/usr/local && make -j$(nproc) && make install && \
    rm -rf /tmp/samtools-1.16.1*

# bcftools 1.16
RUN cd /tmp && \
    wget -q https://github.com/samtools/bcftools/releases/download/1.16/bcftools-1.16.tar.bz2 && \
    tar -xjf bcftools-1.16.tar.bz2 && cd bcftools-1.16 && \
    ./configure --prefix=/usr/local && make -j$(nproc) && make install && \
    rm -rf /tmp/bcftools-1.16*

# bedtools 2.30.0
RUN cd /tmp && \
    wget -q https://github.com/arq5x/bedtools2/releases/download/v2.30.0/bedtools.static.binary && \
    mv bedtools.static.binary /usr/local/bin/bedtools && chmod +x /usr/local/bin/bedtools

# isa-l (igzip) 2.30.0
RUN cd /tmp && \
    wget -q https://github.com/intel/isa-l/archive/refs/tags/v2.30.0.tar.gz && \
    tar -xzf v2.30.0.tar.gz && cd isa-l-2.30.0 && \
    ./autogen.sh && ./configure --prefix=/usr/local && make -j$(nproc) && make install && \
    rm -rf /tmp/isa-l-2.30.0 /tmp/v2.30.0.tar.gz

# jemalloc 5.3.0
RUN cd /tmp && \
    wget -q https://github.com/jemalloc/jemalloc/releases/download/5.3.0/jemalloc-5.3.0.tar.bz2 && \
    tar -xjf jemalloc-5.3.0.tar.bz2 && cd jemalloc-5.3.0 && \
    ./configure --prefix=/usr/local && make -j$(nproc) && make install && \
    rm -rf /tmp/jemalloc-5.3.0*

# Sentieon
RUN cd /opt && \
    wget -q https://s3.amazonaws.com/sentieon-release/software/sentieon-genomics-${SENTIEON_VERSION}.tar.gz && \
    tar -xzf sentieon-genomics-${SENTIEON_VERSION}.tar.gz && \
    rm -f sentieon-genomics-${SENTIEON_VERSION}.tar.gz

# --- Final stage ---
FROM amazonlinux:2

ARG SENTIEON_VERSION=202503.03

RUN yum update -y && yum install -y \
    zlib bzip2-libs xz-libs libcurl ncurses-libs openssl-libs \
    python3 awscli \
    && yum clean all

COPY --from=build /usr/local/bin/ /usr/local/bin/
COPY --from=build /usr/local/lib/ /usr/local/lib/
COPY --from=build /usr/local/include/ /usr/local/include/
COPY --from=build /opt/sentieon-genomics-${SENTIEON_VERSION} /opt/sentieon-genomics-${SENTIEON_VERSION}

ENV SENTIEON_INSTALL_DIR=/opt/sentieon-genomics-${SENTIEON_VERSION}
ENV PATH=${SENTIEON_INSTALL_DIR}/bin:/usr/local/bin:$PATH
ENV SENTIEON_JEMALLOC=/usr/local/lib/libjemalloc.so.2
ENV MALLOC_CONF=metadata_thp:auto,background_thread:true,dirty_decay_ms:30000,muzzy_decay_ms:30000
ENV LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH

LABEL maintainer="NEA-EHI WGS Pipeline"
LABEL description="Sentieon DNAscope for Ae. aegypti WGS on AWS HealthOmics"

WORKDIR /data
