#!/usr/bin/env Rscript
# NEA/EHI Stochastic Simulation Runner
# Entrypoint for AWS Batch jobs
# Supports: single-run mode and parameter estimation mode

library(DBI)
library(RPostgres)
library(jsonlite)
library(dplyr)

# Environment variables set by AWS Batch job definition
s3_bucket    <- Sys.getenv("S3_BUCKET")
run_mode     <- Sys.getenv("RUN_MODE", "single")     # "single" or "param-estimation"
num_chains   <- as.integer(Sys.getenv("NUM_CHAINS", "4"))
iterations   <- as.integer(Sys.getenv("ITERATIONS", "5000"))
chain_index  <- as.integer(Sys.getenv("AWS_BATCH_JOB_ARRAY_INDEX", "0"))

cat(sprintf("=== NEA/EHI Simulation Runner ===\n"))
cat(sprintf("Mode: %s | Chain: %d | Iterations: %d\n", run_mode, chain_index, iterations))

# --- Database Connection ---
get_db_connection <- function() {
  secret_json <- system("aws secretsmanager get-secret-value --secret-id nea-ehi-poc/rds-master --query SecretString --output text", intern = TRUE)
  creds <- fromJSON(secret_json)

  dbConnect(
    RPostgres::Postgres(),
    host     = creds$host,
    port     = as.integer(creds$port),
    dbname   = "nea_ehi",
    user     = creds$username,
    password = creds$password,
    sslmode  = "require"
  )
}

# --- Load Parameters from RDS ---
load_parameters <- function(con) {
  # Load simulation parameters from database
  params <- dbGetQuery(con, "
    SELECT * FROM simulation_params
    WHERE active = TRUE
    ORDER BY created_at DESC
    LIMIT 1
  ")

  if (nrow(params) == 0) {
    stop("No active simulation parameters found in database")
  }

  fromJSON(params$params_json[1])
}

# --- Simulation Core ---
# 4,000 state variables: 66 age groups x 62 disease components + 11 mosquito components
run_single_simulation <- function(params, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  start_time <- Sys.time()
  cat(sprintf("Starting simulation at %s\n", start_time))

  # Placeholder for actual NEA simulation code
  # This will be replaced with Chia-Chen's R + Julia simulation logic
  n_days <- 36500  # 100 years, daily timestep
  n_age_groups <- 66
  n_disease_components <- 62
  n_mosquito_components <- 11
  n_states <- n_age_groups * n_disease_components + n_mosquito_components  # ~4,103

  # Initialize state vector
  state <- rep(0, n_states)

  # Simulation loop (placeholder — actual ODE/stochastic logic from NEA team)
  results <- list()
  for (day in seq_len(n_days)) {
    # Daily state update (placeholder)
    state <- state + rnorm(n_states, mean = 0, sd = 0.01)

    # Save daily snapshot
    if (day %% 365 == 0) {
      results[[length(results) + 1]] <- list(
        day = day,
        summary = summary(state)
      )
    }
  }

  elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
  cat(sprintf("Simulation completed in %.1f seconds\n", elapsed))

  list(
    results = results,
    runtime_sec = elapsed,
    n_days = n_days,
    n_states = n_states
  )
}

# --- Parameter Estimation (MCMC) ---
run_parameter_estimation <- function(params, chain_idx, n_iter) {
  start_time <- Sys.time()
  cat(sprintf("Starting parameter estimation: chain %d, %d iterations\n", chain_idx, n_iter))

  set.seed(42 + chain_idx)

  # Placeholder for MCMC parameter estimation
  # Will be replaced with Chia-Chen's actual estimation code
  posterior_samples <- matrix(rnorm(n_iter * 10), nrow = n_iter, ncol = 10)
  colnames(posterior_samples) <- paste0("param_", 1:10)

  elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
  cat(sprintf("Parameter estimation chain %d completed in %.1f seconds\n", chain_idx, elapsed))

  list(
    chain = chain_idx,
    posterior = posterior_samples,
    runtime_sec = elapsed,
    iterations = n_iter
  )
}

# --- Upload Results to S3 ---
upload_to_s3 <- function(result, run_id) {
  output_path <- sprintf("/tmp/%s.json", run_id)
  writeLines(toJSON(result, auto_unbox = TRUE), output_path)

  s3_key <- sprintf("results/simulation/%s.json", run_id)
  system(sprintf("aws s3 cp %s s3://%s/%s --sse aws:kms", output_path, s3_bucket, s3_key))
  cat(sprintf("Results uploaded to s3://%s/%s\n", s3_bucket, s3_key))

  s3_key
}

# --- Record Run in RDS ---
record_run <- function(con, run_id, model_type, params_json, status, result_path, runtime_sec) {
  dbExecute(con, "
    INSERT INTO simulation_runs (run_id, model_type, params, status, result_path, runtime_sec)
    VALUES ($1, $2, $3::jsonb, $4, $5, $6)
  ", list(run_id, model_type, params_json, status, result_path, runtime_sec))
}

# --- Main ---
main <- function() {
  con <- get_db_connection()
  on.exit(dbDisconnect(con))

  params <- load_parameters(con)
  run_id <- sprintf("sim_%s_%s_%d", run_mode, format(Sys.time(), "%Y%m%d_%H%M%S"), chain_index)

  tryCatch({
    if (run_mode == "single") {
      result <- run_single_simulation(params)
    } else if (run_mode == "param-estimation") {
      result <- run_parameter_estimation(params, chain_index, iterations)
    } else {
      stop(sprintf("Unknown run mode: %s", run_mode))
    }

    s3_path <- upload_to_s3(result, run_id)
    record_run(con, run_id, run_mode, toJSON(params, auto_unbox = TRUE), "completed", s3_path, result$runtime_sec)
    cat("=== Simulation completed successfully ===\n")
  }, error = function(e) {
    cat(sprintf("ERROR: %s\n", e$message))
    record_run(con, run_id, run_mode, toJSON(params, auto_unbox = TRUE), "failed", NA, NA)
    quit(status = 1)
  })
}

main()
