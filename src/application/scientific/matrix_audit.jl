"""Matrix spectral sum and negative phase-space weights on the actual final grid."""
function _measure_final_matrix_audit(solution::NEGFSolution)
    problem=solution.problem
    green=solution.scba.green
    NE, Nk, Nb=problem.numerical.N_E, problem.numerical.N_k, problem.numerical.N_b
    integral=zeros(ComplexF64, Nk, Nb, Nb)
    cumulative=zeros(Float64, NE, Nk)
    eigenvalues=zeros(Float64, Nk, Nb)
    negative=zeros(Float64, 6, Nk)
    negative_blocks=zeros(Int64, 6)
    beyond_budget=zeros(Int64, 6)
    invalid_blocks=zeros(Int64, 6)
    witnesses=fill(_empty_positivity_witness(), 6)
    kinds=(
        "spectral",
        "occupied",
        "unoccupied",
        "broadening",
        "raw_occupied",
        "raw_unoccupied",
    )
    for k = 1:Nk
        for e = 1:NE
            weight=problem.grids.wᴱ[e]/(2π)
            integral[k, :, :] .+= weight .* view(green.A, e, k, :, :)
            cumulative[e, k]=real(tr(view(integral, k, :, :)))
            blocks=_scba_positivity_blocks(solution.scba, problem.kernels.enabled, e, k)
            for (index, (_, block)) in enumerate(blocks)
                values=_diagnostic_eigenvalues(block)
                witness=_positivity_witness(
                    Symbol(kinds[index]),
                    e,
                    k,
                    values;
                    hermiticity_defect = all(isfinite, block) ? norm(block-block')/2 : Inf,
                )
                witness.ratio>witnesses[index].ratio && (witnesses[index]=witness)
                if !all(isfinite, values)
                    negative[index, k]=NaN
                    invalid_blocks[index]+=1
                    continue
                end
                negative[index, k]+=weight*sum(value->max(0.0, -value), values)
                negative_blocks[index]+=minimum(values)<0
                beyond_budget[index]+=minimum(values)<-psd_error_budget(
                    maximum(abs, values),
                    Nb,
                )
            end
        end
        eigenvalues[k, :]=_diagnostic_eigenvalues(Matrix(view(integral, k, :, :)))
    end
    # Broadening has different units and is kept in scaled form above.
    indices=[1, 2, 3, 5, 6]
    weights=Float64[
        problem.physical.g_s*sum(negative[i, :] .* problem.grids.wᵏ)/problem.scales.L₀_m^2
        for i in indices
    ]
    return (;
        integral,
        cumulative,
        eigenvalues,
        negative,
        negative_blocks,
        beyond_budget,
        invalid_blocks,
        total_blocks_per_kind = NE*Nk,
        kinds,
        green_kinds = collect(kinds)[indices],
        weights,
        witnesses,
    )
end

function _diagnostic_eigenvalues(block)
    all(isfinite, block) || return fill(NaN, size(block, 1))
    try
        return eigvals(Hermitian((block+block')/2))
    catch error
        error isa LinearAlgebra.LAPACKException || rethrow()
        return fill(NaN, size(block, 1))
    end
end
