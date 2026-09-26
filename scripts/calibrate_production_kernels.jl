#!/usr/bin/env julia
"""Bounded fixed-work calibration of the real production SCBA primitives.

Usage: julia --project --threads=N calibrate_production_kernels.jl PLAN OUTPUT EXECUTION_ID STEPS
The caller owns affinity and concurrency. Only one-point stationary executions
are accepted. A finite unaccepted physical state is useful calibration evidence;
this tool never grants physical or scientific acceptance.
"""
module QCLFixedWorkCalibration
using QCLNEGFRunner
using LinearAlgebra
using SHA
using Unitful
using FFTW

const SCHEMA="qcl-negf-fixed-work-result-v2"
const CONTRACT_SET="qcl-negf.results.v1"

function fixed_work_options(original::SolverOptions, steps::Integer)
    2 <= steps <= 10_000 || throw(ArgumentError("fixed-work steps must lie in [2,10000]"))
    # Thresholds and equations are unchanged. A confirmation count larger than
    # the declared work prevents early convergence; stagnation and approximate
    # exits are disabled. Numerical failures still abort and cannot certify a
    # successful calibration. The selected physical map is never simplified.
    old=original.convergence
    changes=(;
        mode = :strict_fail_fast,
        minimum_scba_iterations = Int(steps),
        required_consecutive_scba_passes = Int(steps)+1,
        stagnation_window = 0,
        stagnation_relative_improvement = 0.0,
        diagnostic_quality = DiagnosticQualityPolicy(enabled = false),
    )
    policy=ConvergencePolicy(;
        (
            name=>hasproperty(changes, name) ? getproperty(changes, name) :
                  getfield(old, name) for name in fieldnames(ConvergencePolicy)
        )...,
    )
    return SolverOptions(;
        (
            name=>name===:max_scba ? Int(steps) :
                  name===:convergence ? policy : getfield(original, name) for
            name in fieldnames(SolverOptions)
        )...,
    )
end

function workload_fingerprint(
    plan_bytes::Vector{UInt8},
    execution_id::AbstractString,
    steps::Integer,
)
    return bytes2hex(
        sha256(
            vcat(
                plan_bytes,
                UInt8[0],
                collect(codeunits(execution_id)),
                UInt8[0],
                collect(codeunits(string(steps))),
            ),
        ),
    )
end

function _write_state(
    path::AbstractString,
    problem::NEGFProblem,
    state::SCBAResult,
    U,
    density,
)
    names=String[]
    function write_array(file, name, value)
        all(isfinite, value) || throw(ArgumentError("nonfinite calibration dataset $name"))
        file[name]=value
        push!(names, name)
    end
    function write_complex(file, name, value)
        write_array(file, name*"_real", real.(value))
        write_array(file, name*"_imag", imag.(value))
    end
    function write_family(file, prefix, family)
        write_complex(file, prefix*"SR", family.Σᴿ)
        write_complex(file, prefix*"SL", family.Σˡ)
        write_complex(file, prefix*"SG", family.Σᵍ)
    end
    QCLNEGFRunner.h5open(path, "w") do file
        for (name, value) in (
            ("GR", state.green.Gᴿ),
            ("GL", state.green.Gˡ),
            ("GG", state.green.Gᵍ),
            ("A", state.green.A),
        )
            write_complex(file, name, value)
        end
        total=QCLNEGFRunner._total_family(
            state.scattering,
            state.embedding,
            size(state.green.Gᴿ),
        )
        write_family(file, "", total)
        for name in sort!(collect(keys(state.scattering)); by = String)
            write_family(file, "scattering_"*String(name)*"_", state.scattering[name])
        end
        write_family(file, "embedding_", state.embedding)
        write_family(file, "embedding_plus_", state.embedding_plus)
        write_family(file, "embedding_minus_", state.embedding_minus)
        for (name, value) in (
            ("U", U),
            ("n", density),
            ("energy", problem.grids.ε),
            ("k", problem.grids.κ),
            ("wE", problem.grids.wᴱ),
            ("wk", problem.grids.wᵏ),
            ("z", problem.grids.x),
            ("wz", problem.grids.wˣ),
        )
            write_array(file, name, value)
        end
        write_complex(file, "H", project_hamiltonians(problem, U))
        # The first observable-change sentinel is deliberately not stored as
        # a raw physical number. These eight measured equations are finite at
        # every successful fixed-work iteration, including the first one.
        columns=(:r_D, :r_A, :r_K, :r_Σ, :r_λ, :r_PSD, :r_caus, :r_roundoff)
        history=[getfield(row, name) for row in state.history, name in columns]
        write_array(file, "history_raw", history)
        attributes=QCLNEGFRunner.attributes(file)
        attributes["schema"]=SCHEMA
        attributes["contract_set"]=CONTRACT_SET
        attributes["physical_accepted"]=false
        attributes["history_columns"]=join(String.(columns), ",")
        attributes["complex_encoding"]="paired Float64 real/imag datasets; original Julia E,k,b,b axes"
        attributes["julia_version"]=string(VERSION)
        attributes["energy_unit"]="scaled (E-E_ref)/E0"
        attributes["momentum_unit"]="scaled k*L0"
        attributes["hartree_unit"]="scaled U/E0"
        attributes["density_unit"]="scaled n*L0^3"
        attributes["energy_scale_eV"]=problem.scales.E₀_eV
        attributes["reference_energy_eV"]=ustrip(
            u"eV",
            uconvert(u"eV", problem.physical.E_ref),
        )
        attributes["length_scale_m"]=problem.scales.L₀_m
        attributes["toolchain_json"]=sprint(
            QCLNEGFRunner._light_json,
            QCLNEGFRunner._runtime_toolchain_provenance(),
        )
    end
    return sort!(names)
end

function _phase_cost_observer(measurements::Dict{String,Dict{String,Any}})
    return function (event)
        event.action === :phase_end || return nothing
        values=Dict(String(metric.name)=>metric.value for metric in event.metrics)
        phase=get!(measurements, event.label) do
            Dict{String,Any}(
                "calls"=>0,
                "wall_seconds"=>0.0,
                "cpu_seconds"=>0.0,
                "allocated_bytes"=>0,
                "gc_seconds"=>0.0,
                "gc_count"=>0,
                "task_width_min"=>typemax(Int),
                "task_width_max"=>0,
                "work_units"=>0,
            )
        end
        phase["calls"]+=1
        for (source, target) in (
            ("duration_seconds", "wall_seconds"),
            ("cpu_seconds", "cpu_seconds"),
            ("allocated_bytes", "allocated_bytes"),
            ("gc_seconds", "gc_seconds"),
            ("gc_count", "gc_count"),
            ("work_units", "work_units"),
        )
            haskey(values, source) && (phase[target]+=values[source])
        end
        width=Int(get(values, "task_width", 1))
        phase["task_width_min"]=min(phase["task_width_min"], width)
        phase["task_width_max"]=max(phase["task_width_max"], width)
        return nothing
    end
end

function calibrate(
    plan_path::AbstractString,
    output::AbstractString,
    execution_id::AbstractString,
    steps::Integer,
)
    fixed_work_options(SolverOptions(), steps)
    plan_bytes=read(plan_path)
    plan=load_scientific_plan(plan_path)
    selected=[execution for execution in plan.executions if execution.id==execution_id]
    length(selected)==1 || throw(
        ArgumentError("fixed-work execution ID must identify exactly one frozen execution"),
    )
    execution=only(selected)
    execution.operation===:stationary ||
        throw(ArgumentError("fixed-work requires operation=stationary"))
    length(execution.point_ids)==1 ||
        throw(ArgumentError("fixed-work requires exactly one operating point"))
    point=only(point for point in plan.points if point.id==only(execution.point_ids))
    configuration=execution.configuration
    configuration.execution.solver_backend===:production ||
        throw(ArgumentError("fixed-work requires the production backend"))
    isdir(output) &&
        !isempty(readdir(output)) &&
        throw(ArgumentError("calibration output must be a new or empty directory"))
    mkpath(output)
    BLAS.set_num_threads(1)
    FFTW.set_num_threads(1)
    build_started=time_ns()
    configured=build_configured_problem(configuration)
    problem=retarget_problem(
        configured.problem;
        V_period = point.voltage_per_period_V*u"V",
        Tᴸ = point.temperature_K*u"K",
        Tᴸᴼ = point.temperature_K*u"K",
        energy_shift = configuration.algorithms.energy_shift,
    )
    phase_measurements=Dict{String,Dict{String,Any}}()
    phase_observer=_phase_cost_observer(phase_measurements)
    production=QCLNEGFRunner.with_production_options(
        configuration.production;
        worker_count = Threads.nthreads(:default),
        parallel_backend = :threads,
        phase_timing = true,
        checkpoint_every_scba = 0,
        checkpoint_every_outer = 0,
        progress_every_scba = 0,
        progress_every_outer = 0,
        event_sink = phase_observer,
        phase_request = QCLNEGFRunner._native_phase_request(String(output)),
    )
    cache=build_production_cache(problem; options = production)
    build_seconds=(time_ns()-build_started)/1e9
    options=fixed_work_options(configuration.solver, steps)
    U=zeros(problem.numerical.N_z)
    kernel_started=time_ns()
    state=solve_scba_production(problem, U; options, production_options = production, cache)
    kernel_seconds=(time_ns()-kernel_started)/1e9
    length(state.history)==steps && last(state.history).ν==steps || throw(
        ArgumentError("fixed-work solver did not execute the declared number of cycles"),
    )
    state.quality!==:invalid ||
        throw(ArgumentError("fixed-work solver returned an invalid state"))
    density=QCLNEGFRunner._electron_density_bar(problem, state.green.Gˡ)
    last_row=last(state.history)
    scientific=Dict{String,Float64}(
        "J_A_per_m2"=>last_row.J,
        "sheet_density_scaled"=>number_functional(
            state.green.Gˡ,
            problem.grids,
            problem.physical.g_s,
        ),
        "r_D"=>last_row.r_D,
        "r_K"=>last_row.r_K,
        "r_Sigma"=>last_row.r_Σ,
        "r_lambda"=>last_row.r_λ,
        "r_PSD"=>last_row.r_PSD,
        "r_caus"=>last_row.r_caus,
    )
    all(isfinite, values(scientific)) ||
        throw(ArgumentError("nonfinite fixed-work observables"))
    arrays_path=joinpath(output, "calibration-state.h5")
    temporary_arrays=arrays_path*".pending"
    datasets=_write_state(temporary_arrays, problem, state, U, density)
    mv(temporary_arrays, arrays_path)
    fingerprint=workload_fingerprint(plan_bytes, execution_id, steps)
    result=Dict{String,Any}(
        "schema"=>SCHEMA,
        "contract_set"=>CONTRACT_SET,
        "status"=>"completed",
        "physical_accepted"=>false,
        "scientific_accepted"=>false,
        "execution_id"=>String(execution_id),
        "point_id"=>point.id,
        "plan_fingerprint"=>plan.fingerprint,
        "plan_sha256"=>bytes2hex(sha256(plan_bytes)),
        "effective_input_fingerprint"=>fingerprint,
        "workload_sha256"=>fingerprint,
        "kernel_calls"=>Int(steps),
        "total_candidate_calls"=>Int(steps)+1,
        "initialization_candidate_calls"=>1,
        "work_unit"=>"one full production SCBA candidate/Dyson/residual cycle; one initialization candidate is separate",
        "arrays_file"=>basename(arrays_path),
        "arrays_sha256"=>bytes2hex(open(sha256, arrays_path)),
        "state_datasets"=>datasets,
        "scientific_observables"=>scientific,
        "kernel_seconds"=>kernel_seconds,
        "phase_measurements"=>phase_measurements,
        "phase_measurement_scope"=>"inclusive process counters; nested phases overlap; do not sum",
        "profiling_in_kernel_seconds"=>true,
        "build_seconds"=>build_seconds,
        "timing_scope"=>"kernel_seconds includes seed and exactly N fixed-Hartree cycles; excludes problem/cache construction and output I/O",
        "solver_status"=>String(state.status),
        "solver_quality"=>String(state.quality),
        "runtime"=>Dict(
            "julia_version"=>string(VERSION),
            "julia_threads"=>Threads.nthreads(:default),
            "blas_threads"=>BLAS.get_num_threads(),
            "fftw_threads"=>FFTW.get_num_threads(),
        ),
        "harness_sha256"=>bytes2hex(open(sha256, @__FILE__)),
        "toolchain"=>QCLNEGFRunner._runtime_toolchain_provenance(),
        "calibration_overrides"=>Dict(
            "fixed_hartree"=>true,
            "cold_seed"=>true,
            "parallel_backend"=>"threads",
            "early_convergence"=>false,
            "stagnation"=>false,
            "approximate_exit"=>false,
            "max_scba"=>Int(steps),
            "required_consecutive_scba_passes"=>Int(steps)+1,
        ),
    )
    temporary_result=joinpath(output, "calibration-result.json.pending")
    open(temporary_result, "w") do io
        QCLNEGFRunner._light_json(io, result)
        write(io, '\n')
    end
    mv(temporary_result, joinpath(output, "calibration-result.json"))
    return result
end

function main(arguments)
    length(arguments)==4 || throw(
        ArgumentError(
            "usage: calibrate_production_kernels.jl PLAN OUTPUT EXECUTION_ID STEPS",
        ),
    )
    calibrate(arguments[1], abspath(arguments[2]), arguments[3], parse(Int, arguments[4]))
    return nothing
end
end

if abspath(PROGRAM_FILE)==@__FILE__
    try
        QCLFixedWorkCalibration.main(ARGS)
    catch exception
        if exception isa Union{ArgumentError,QCLFixedWorkCalibration.ConfigurationError}
            println(stderr, sprint(showerror, exception))
            exit(2)
        end
        rethrow()
    end
end
