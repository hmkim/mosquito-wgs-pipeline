FROM rocker/r-ver:4.4.0

LABEL maintainer="NEA/EHI POC Team"
LABEL description="R + Julia simulation container for stochastic epidemiological modelling"

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    curl \
    libpq-dev \
    libssl-dev \
    libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Julia 1.10
RUN wget -qO- https://julialang-s3.julialang.org/bin/linux/x64/1.10/julia-1.10.4-linux-x86_64.tar.gz \
    | tar -xzf - -C /opt/ \
    && ln -s /opt/julia-1.10.4/bin/julia /usr/local/bin/julia

# Install R packages for simulation and DB connectivity
RUN R -e 'install.packages(c( \
    "DBI", \
    "RPostgres", \
    "jsonlite", \
    "aws.s3", \
    "dplyr", \
    "tidyr", \
    "purrr" \
), repos="https://cloud.r-project.org/")'

# Install Julia packages
RUN julia -e 'using Pkg; Pkg.add(["DifferentialEquations", "Distributions", "JSON", "CSV", "DataFrames"])'

# Copy simulation entrypoint
COPY run_simulation.R /app/run_simulation.R
COPY run_simulation.jl /app/run_simulation.jl

WORKDIR /app

ENTRYPOINT ["Rscript", "/app/run_simulation.R"]
