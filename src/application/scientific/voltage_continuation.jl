# Ready Core summaries only: no equations, metrics or numerical arrays are evaluated.
_voltage_field(value, name::Symbol) =
    value !== nothing && hasproperty(value, name) ? getproperty(value, name) : nothing

function _voltage_certificate_reason(assessment)
    assessment isa AbstractDict || return :missing_or_malformed_stationary_assessment
    version=get(assessment, "registry_version", nothing)
    version isa AbstractString && version=="qcl-negf-acceptance-metadata-v1" ||
        return :unknown_stationary_assessment_registry
    for key in ("stationary_candidate_accepted", "iterative_converged",
                "fixed_hartree_converged", "physical_gates_passed")
        get(assessment, key, nothing)===true || return :stationary_certificate_not_passed
    end
    return nothing
end

function _strict_voltage_state(summary)
    return _voltage_field(summary, :status)===:converged &&
           _voltage_field(summary, :converged)===true &&
           _voltage_field(summary, :quality)===:strict &&
           _voltage_field(summary, :inner_status)===:converged &&
           _voltage_field(summary, :inner_converged)===true &&
           _voltage_field(summary, :inner_quality)===:strictly_converged &&
           _voltage_field(summary, :certificate)===true
end
_usable_voltage_state(summary, mode) = mode===:strict && _strict_voltage_state(summary)

function _voltage_seed_summary(status, converged, quality, inner_status,
                               inner_converged, inner_quality, reason)
    summary=(; status, converged, quality, inner_status, inner_converged,
        inner_quality, certificate=reason===nothing, reason)
    if reason===nothing && !_strict_voltage_state(summary)
        return merge(summary, (; reason=:inconsistent_final_state))
    end
    return summary
end

function _live_voltage_seed_summary(solution, quality, assessment)
    reason=_voltage_certificate_reason(assessment)
    if reason===nothing && _voltage_field(_voltage_field(solution, :report), :passed)!==true
        reason=:final_report_not_passed
    end
    inner=_voltage_field(solution, :scba)
    return _voltage_seed_summary(
        _voltage_field(solution, :status), _voltage_field(solution, :converged), quality,
        _voltage_field(inner, :status), _voltage_field(inner, :converged),
        _voltage_field(inner, :quality), reason,
    )
end

# Caller supplies the retained commit returned by existing artifact verification.
# Original final flags are authority; saved.scba.status=:restart is operational.
function _restored_voltage_seed_summary(commit, saved, old)
    assessment=commit isa AbstractDict ? get(commit, "stationary_assessment", nothing) : nothing
    reason=_voltage_certificate_reason(assessment)
    if reason===nothing
        terminal=get(commit, "terminal_status", nothing)
        quality=get(commit, "quality", nothing)
        if !(terminal isa String && terminal=="converged" &&
             quality isa String && quality=="strict" &&
             _voltage_field(old, :status)===:completed)
            reason=:inconsistent_persisted_final_metadata
        end
    end
    return _voltage_seed_summary(
        _voltage_field(saved, :status), _voltage_field(old, :converged),
        _voltage_field(old, :quality), _voltage_field(saved, :original_scba_status),
        _voltage_field(saved, :original_scba_converged),
        _voltage_field(saved, :original_scba_quality), reason,
    )
end
