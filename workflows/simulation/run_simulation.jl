#=
NEA/EHI Stochastic Epidemiological Simulation — Julia Core
Called from run_simulation.R via system() or JuliaCall

State space: 4,000+ variables
- 66 age groups × 62 disease components = 4,092 human states
- 11 mosquito compartment states
- Daily timestep, 36,500-day simulation (100 years)

This is a placeholder to be replaced with Chia-Chen CHANG's actual model.
=#

using DifferentialEquations
using Distributions
using Random
using JSON
using CSV
using DataFrames

# ============================================================
# Model Parameters
# ============================================================
struct DengueParams
    n_age_groups::Int          # 66
    n_disease_components::Int  # 62
    n_mosquito_components::Int # 11
    beta::Float64              # Transmission rate
    mu_h::Float64              # Human mortality rate
    mu_v::Float64              # Mosquito mortality rate
    gamma::Float64             # Recovery rate
    sigma::Float64             # Incubation rate
    alpha::Vector{Float64}     # Age-specific contact rates
end

function default_params()
    n_age = 66
    DengueParams(
        n_age,
        62,
        11,
        0.5,    # beta
        1/25550, # mu_h (~70 years)
        1/14,   # mu_v (~14 days)
        1/7,    # gamma (~7 days recovery)
        1/5.5,  # sigma (~5.5 days incubation)
        ones(n_age) .* 0.1  # uniform contact rates (placeholder)
    )
end

# ============================================================
# State Vector Layout
# ============================================================
# Human states: [age_group, disease_component]
# Mosquito states: [compartment]
# Total: 66 * 62 + 11 = 4,103

function state_size(p::DengueParams)
    p.n_age_groups * p.n_disease_components + p.n_mosquito_components
end

# ============================================================
# Stochastic Model (SDE)
# ============================================================
function dengue_drift!(du, u, p::DengueParams, t)
    n_human = p.n_age_groups * p.n_disease_components
    n_total = state_size(p)

    # Human compartment dynamics (placeholder)
    for i in 1:n_human
        age = ((i - 1) % p.n_age_groups) + 1
        du[i] = -p.mu_h * u[i] + p.sigma * max(0, u[max(1, i-1)]) - p.gamma * u[i]
    end

    # Mosquito dynamics (placeholder)
    for j in (n_human+1):n_total
        du[j] = p.beta * u[j] - p.mu_v * u[j]
    end
end

function dengue_diffusion!(du, u, p::DengueParams, t)
    n_total = state_size(p)
    for i in 1:n_total
        du[i] = sqrt(max(0.0, abs(u[i]))) * 0.01  # Small stochastic perturbation
    end
end

# ============================================================
# Single Simulation Run
# ============================================================
function run_single(params::DengueParams, n_days::Int, seed::Int)
    Random.seed!(seed)
    n = state_size(params)

    # Initial conditions
    u0 = zeros(Float64, n)
    n_human = params.n_age_groups * params.n_disease_components

    # Initialize susceptible population across age groups
    for age in 1:params.n_age_groups
        u0[age] = 1000.0  # Susceptible pool
    end

    # Initialize mosquito compartments
    for j in (n_human+1):n
        u0[j] = 500.0  # Mosquito population
    end

    tspan = (0.0, Float64(n_days))
    prob = SDEProblem(dengue_drift!, dengue_diffusion!, u0, tspan, params)

    sol = solve(prob, EM(), dt=1.0, saveat=1.0)

    return sol
end

# ============================================================
# Parameter Estimation (Metropolis-Hastings MCMC)
# ============================================================
function run_mcmc_chain(
    params::DengueParams,
    observed_data::Vector{Float64},
    chain_index::Int,
    n_iterations::Int,
    seed::Int
)
    Random.seed!(seed + chain_index)

    # Parameter vector to estimate: [beta, gamma, sigma, mu_v]
    current = [params.beta, params.gamma, params.sigma, params.mu_v]
    n_params = length(current)

    # Proposal standard deviations
    proposal_sd = [0.05, 0.02, 0.02, 0.005]

    # Storage
    chain = zeros(Float64, n_iterations, n_params)
    log_likelihoods = zeros(Float64, n_iterations)
    accept_count = 0

    current_ll = -Inf

    for iter in 1:n_iterations
        # Propose
        proposed = current .+ randn(n_params) .* proposal_sd

        # Ensure positivity
        if any(proposed .<= 0)
            chain[iter, :] = current
            log_likelihoods[iter] = current_ll
            continue
        end

        # Evaluate (placeholder — simplified likelihood)
        proposed_ll = -sum((observed_data .- proposed[1] .* 100) .^ 2) / (2 * 100^2)

        # Accept/reject
        log_alpha = proposed_ll - current_ll
        if log(rand()) < log_alpha
            current = proposed
            current_ll = proposed_ll
            accept_count += 1
        end

        chain[iter, :] = current
        log_likelihoods[iter] = current_ll

        if iter % 500 == 0
            acceptance_rate = accept_count / iter
            println("Chain $chain_index | Iter $iter/$n_iterations | Accept rate: $(round(acceptance_rate, digits=3))")
        end
    end

    acceptance_rate = accept_count / n_iterations
    println("Chain $chain_index complete. Final acceptance rate: $(round(acceptance_rate, digits=3))")

    return Dict(
        "chain" => chain_index,
        "samples" => chain,
        "log_likelihoods" => log_likelihoods,
        "acceptance_rate" => acceptance_rate,
        "n_iterations" => n_iterations
    )
end

# ============================================================
# Main Entrypoint
# ============================================================
function main()
    run_mode = get(ENV, "RUN_MODE", "single")
    chain_index = parse(Int, get(ENV, "AWS_BATCH_JOB_ARRAY_INDEX", "0"))
    n_iterations = parse(Int, get(ENV, "ITERATIONS", "5000"))
    seed = 42

    params = default_params()
    println("State vector size: $(state_size(params))")

    if run_mode == "single"
        println("=== Running single simulation (36,500 days) ===")
        sol = run_single(params, 36500, seed)
        println("Simulation complete. Timepoints: $(length(sol.t))")

        # Save summary to JSON
        result = Dict(
            "mode" => "single",
            "n_days" => 36500,
            "n_states" => state_size(params),
            "n_timepoints" => length(sol.t),
            "final_state_summary" => Dict(
                "mean" => mean(sol.u[end]),
                "max" => maximum(sol.u[end]),
                "min" => minimum(sol.u[end])
            )
        )
        open("/tmp/julia_result.json", "w") do f
            JSON.print(f, result)
        end

    elseif run_mode == "param-estimation"
        println("=== Running MCMC parameter estimation ===")
        println("Chain: $chain_index | Iterations: $n_iterations")

        # Placeholder observed data
        observed = randn(100) .* 30 .+ 50

        result = run_mcmc_chain(params, observed, chain_index, n_iterations, seed)

        # Save chain to JSON
        open("/tmp/julia_result.json", "w") do f
            JSON.print(f, Dict(
                "mode" => "param-estimation",
                "chain" => chain_index,
                "iterations" => n_iterations,
                "acceptance_rate" => result["acceptance_rate"],
                "posterior_mean" => vec(mean(result["samples"], dims=1))
            ))
        end
    else
        error("Unknown RUN_MODE: $run_mode")
    end

    println("=== Julia simulation runner complete ===")
end

# Run
main()
