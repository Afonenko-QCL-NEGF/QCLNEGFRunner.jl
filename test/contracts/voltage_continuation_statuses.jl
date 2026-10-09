module VoltageContinuationStatuses
using Test
const application = normpath(joinpath(@__DIR__, "..", "..", "src", "application", "scientific"))
include(joinpath(application, "contracts.jl"))
const helper = joinpath(application, "voltage_continuation.jl")
isfile(helper) && include(helper)

@testset "Executable voltage policies retire finite research predecessors" begin
    @test VoltageContinuation().mode === :independent
    @test VoltageContinuation(:strict).mode === :strict
    @test_throws ArgumentError VoltageContinuation(:research)
    @test_throws ArgumentError VoltageContinuation(:unknown)
    @test ScientificPolicies(:research_continue).scba_to_poisson === :research_continue
    @test ScientificPolicies(:adaptive_working).scba_to_poisson === :adaptive_working
    for name in (:_live_voltage_seed_summary, :_restored_voltage_seed_summary,
                 :_strict_voltage_state, :_usable_voltage_state)
        @test isdefined(@__MODULE__, name)
    end
end

# The baseline has no extracted adapters. Assert their absence above without
# importing the numerical workflow; GREEN exercises the actual production file.
if isfile(helper)
@testset "Strict final certificate alone permits a voltage seed" begin
    assessment = Dict{String,Any}(
        "registry_version" => "qcl-negf-acceptance-metadata-v1",
        "stationary_candidate_accepted" => true, "iterative_converged" => true,
        "fixed_hartree_converged" => true, "physical_gates_passed" => true,
        "scientific_accepted" => false, "discretization_verified" => "not_measured",
        "experimental_validation" => "unknown",
    )
    live = (; status=:converged, converged=true, report=(; passed=true),
        scba=(; status=:converged, converged=true, quality=:strictly_converged))
    saved = (; status=:converged, original_scba_status=:converged,
        original_scba_converged=true, original_scba_quality=:strictly_converged,
        scba=(; status=:restart))
    old = (; status=:completed, converged=true, quality=:strict,
        warnings=[Dict("code" => "HISTORICAL")])
    commit = Dict{String,Any}("terminal_status" => "converged", "quality" => "strict",
        "stationary_assessment" => deepcopy(assessment))
    snapshot = deepcopy((; assessment, live, saved, old, commit))
    live_summary = _live_voltage_seed_summary(live, :strict, assessment)
    restored_summary = _restored_voltage_seed_summary(commit, saved, old)
    @test _strict_voltage_state(live_summary)
    @test _strict_voltage_state(restored_summary)
    @test _usable_voltage_state(live_summary, :strict)
    @test _usable_voltage_state(restored_summary, :strict)
    for mode in (:independent, :research, :unknown)
        @test !_usable_voltage_state(live_summary, mode)
        @test !_usable_voltage_state(restored_summary, mode)
    end
    inner_cases = [
        (:converged, true, :strictly_converged, true),
        (:approximate, false, :approximate_fixed_point, false),
        (:research_continue, false, :unresolved, false),
        (:max_iterations, false, :unresolved, false),
        (:max_iterations, false, :invalid, false),
        (:stagnated, false, :unresolved, false),
        (:quality_blocked, false, :unresolved, false),
        (:invalid_candidate, false, :invalid, false),
        (:nonfinite_metrics, false, :invalid, false),
        (:running, false, :unresolved, false),
        (:running, false, :approximate_fixed_point, false),
        (:restart, false, :strictly_converged, false),
        (:approximately_converged, false, :approximate_fixed_point, false),
        (:approximate_fixed_point, false, :approximate_fixed_point, false),
        (:unknown, false, :unresolved, false),
    ]
    for (status, converged, quality, allowed) in inner_cases
        candidate = merge(live, (; scba=(; status, converged, quality)))
        @test _usable_voltage_state(_live_voltage_seed_summary(candidate, :strict, assessment), :strict) == allowed
        restored = merge(saved, (; original_scba_status=status,
            original_scba_converged=converged, original_scba_quality=quality))
        @test _usable_voltage_state(_restored_voltage_seed_summary(commit, restored, old), :strict) == allowed
    end
    denied_statuses = [:max_poisson_iterations, :approximate, :final_scba_failed,
        :validation_failed, :outer_limit_with_warning, :running_scba, :running,
        :snapshot, :restart, :completed, :unknown]
    for suffix in (:max_iterations, :stagnated, :quality_blocked, :invalid_candidate,
                   :nonfinite_metrics)
        push!(denied_statuses, Symbol(:scba_, suffix))
    end
    for suffix in (:converged, :approximate, :research_continue, :max_iterations,
                   :stagnated, :quality_blocked, :invalid_candidate, :nonfinite_metrics)
        push!(denied_statuses, Symbol(:max_poisson_iterations_final_scba_, suffix))
    end
    for status in denied_statuses
        @test !_usable_voltage_state(_live_voltage_seed_summary(merge(live, (; status)), :strict, assessment), :strict)
        @test !_usable_voltage_state(_restored_voltage_seed_summary(commit, merge(saved, (; status)), old), :strict)
    end
    for changes in ((; converged=false), (; converged=1), (; report=(; passed=false)),
                    (; report=(; passed=1)), (; report=nothing),
                    (; scba=merge(live.scba, (; converged=false))),
                    (; scba=merge(live.scba, (; status=:approximate))),
                    (; scba=merge(live.scba, (; quality=:unresolved))))
        @test !_usable_voltage_state(_live_voltage_seed_summary(merge(live, changes), :strict, assessment), :strict)
    end
    @test !_usable_voltage_state(_live_voltage_seed_summary(live, :unconverged, assessment), :strict)
    for missing in (nothing, (;), (; status=:exception))
        @test !_usable_voltage_state(_live_voltage_seed_summary(missing, :strict, assessment), :strict)
        @test !_usable_voltage_state(_restored_voltage_seed_summary(commit, missing, old), :strict)
        @test !_usable_voltage_state(missing, :strict)
    end
    certificate_cases = Any[nothing, false, "unknown", 1, Dict{String,Any}()]
    for key in ("stationary_candidate_accepted", "iterative_converged",
                "fixed_hartree_converged", "physical_gates_passed")
        for value in (false, "not_measured", "true", 1, nothing)
            altered = deepcopy(assessment)
            altered[key] = value
            push!(certificate_cases, altered)
        end
        altered = deepcopy(assessment)
        delete!(altered, key)
        push!(certificate_cases, altered)
    end
    for value in ("unknown", nothing, 1)
        altered = deepcopy(assessment)
        altered["registry_version"] = value
        push!(certificate_cases, altered)
    end
    altered = deepcopy(assessment)
    delete!(altered, "registry_version")
    push!(certificate_cases, altered)
    for certificate in certificate_cases
        @test !_usable_voltage_state(_live_voltage_seed_summary(live, :strict, certificate), :strict)
        altered_commit = deepcopy(commit)
        altered_commit["stationary_assessment"] = certificate
        summary = _restored_voltage_seed_summary(altered_commit, saved, old)
        @test !_usable_voltage_state(summary, :strict)
        @test summary.reason !== nothing
    end
    for key in ("terminal_status", "quality", "stationary_assessment")
        altered_commit = deepcopy(commit)
        delete!(altered_commit, key)
        @test !_usable_voltage_state(_restored_voltage_seed_summary(altered_commit, saved, old), :strict)
    end
    for (key, values) in (("terminal_status", ("completed", :converged, "unknown")),
                          ("quality", ("unconverged", :strict, "unknown")))
        for value in values
            altered_commit = deepcopy(commit)
            altered_commit[key] = value
            @test !_usable_voltage_state(_restored_voltage_seed_summary(altered_commit, saved, old), :strict)
        end
    end
    for changes in ((; status=:running), (; converged=false), (; converged=1), (; quality=:unconverged))
        @test !_usable_voltage_state(_restored_voltage_seed_summary(commit, saved, merge(old, changes)), :strict)
    end
    @test !_usable_voltage_state(_restored_voltage_seed_summary(nothing, saved, old), :strict)
    @test !_usable_voltage_state(_restored_voltage_seed_summary(commit, saved, nothing), :strict)
    @test (; assessment, live, saved, old, commit) == snapshot
    @test assessment["scientific_accepted"] === false
    @test assessment["discretization_verified"] == "not_measured"
end
end
end
