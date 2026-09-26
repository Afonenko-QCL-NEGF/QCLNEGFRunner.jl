"""Declared manufactured inputs; never defaults or fitted parameters of a QCL.

Energies are numerical eV coordinates. Γ is the full broadening, so the
retarded self-energy is -iΓ/2. The H and Γ matrices do not commute.
Every report stores the inputs, phase, mesh and the finite-window analytic
truth. Coarse-grid rejection is an expected observation, not acceptance of
an unresolved spectral integral. No SCBA or material adequacy is certified.
"""
const SPECTRAL_RESOLUTION_FIXTURE = (
    levels_eV = [-0.0225, 0.005, 0.0275],
    window_eV = (-0.08, 0.08),
    linewidth_scales_eV = (0.004, 0.0008, 0.00016),
    nodes = (65, 257, 1025, 4097, 16385),
    phases = (0.0, 0.5),
    gamma_shape = ComplexF64[0.7 0.1im 0.05; -0.1im 1.1 0.12; 0.05 0.12 1.4],
    integral_relative_tolerance = 1e-6,
    coarse_rejection_floor = 0.05,
    chain_cells = 5,
    chain_energies_eV = (-0.02, 0.006, 0.025),
    chain_voltage_eV = 0.002,
    chain_linewidth_eV = 0.004,
    chain_hopping_eV = 0.003,
    chain_occupations = [0.2, 0.5, 0.8],
    chain_relative_tolerance = 2e-11,
)

_spectral_complex_record(matrix) = Dict(
    "shape"=>collect(size(matrix)),
    "real"=>[real.(collect(row)) for row in eachrow(matrix)],
    "imag"=>[imag.(collect(row)) for row in eachrow(matrix)],
)

function _spectral_resolution_hamiltonian()
    phase = cis(2π/3)
    transform = ComplexF64[1 1 1; 1 phase phase^2; 1 phase^2 phase]/sqrt(3)
    return transform*Diagonal(SPECTRAL_RESOLUTION_FIXTURE.levels_eV)*transform'
end

"""Independent finite-window integral of the constant-self-energy resolvent.

For B=H-iΓ/2=V diag(z) V⁻¹, L=V diag(log(b-z)-log(a-z)) V⁻¹.
The exact integral of A/(2π) is i(L-L†)/(2π). All poles are strictly in
the lower half-plane, fixing a continuous principal-log branch on real E.
Unlike sampled quadrature this expression resolves arbitrarily narrow poles.
"""
function _constant_selfenergy_spectral_integral(H, gamma, lower, upper)
    lower < upper || throw(ArgumentError("invalid spectral oracle window"))
    eigmin(Hermitian(gamma)) > 0 ||
        throw(ArgumentError("oracle Γ must be positive definite"))
    decomposition = eigen(H-im*gamma/2)
    all(z -> imag(z)<0, decomposition.values) || error("noncausal oracle poles")
    logarithms = log.(upper .- decomposition.values) .- log.(lower .- decomposition.values)
    integrated_R = decomposition.vectors*Diagonal(logarithms)/decomposition.vectors
    return Matrix(Hermitian(im*(integrated_R-integrated_R')/(2π)))
end

function _spectral_resolution_sample(H, gamma, nodes, phase)
    fixture = SPECTRAL_RESOLUTION_FIXTURE
    lower, upper = fixture.window_eV
    step = (upper-lower)/(nodes-1)
    lower += phase*step
    upper += phase*step
    energies = collect(range(lower, upper; length = nodes))
    weights = fill(step, nodes)
    weights[[1, end]] ./= 2
    count = size(H, 1)
    h = reshape(H, 1, count, count)
    sigma_R = [-(im/2)*gamma[a, b] for e = 1:nodes, m = 1:1, a = 1:count, b = 1:count]
    options = _DIAGNOSTIC_CORE.ProductionOptions(worker_count = 1)
    green, _, _ = _DIAGNOSTIC_CORE._retarded_green_production(energies, h, sigma_R; options)
    spectral = _DIAGNOSTIC_CORE.spectral_function(green)
    integral = zeros(ComplexF64, count, count)
    for e in eachindex(energies)
        integral .+= weights[e]/(2π) .* view(spectral, e, 1, :, :)
    end
    truth = _constant_selfenergy_spectral_integral(H, gamma, lower, upper)
    # The same production marker used during SCBA is checked independently
    # against Rayleigh bounds of this explicitly known constant Γ.
    total = _DIAGNOSTIC_CORE.SelfEnergyFamily(sigma_R, -sigma_R, sigma_R)
    markers = _DIAGNOSTIC_CORE.QCLNumerics._sampled_linewidth_markers(
        spectral,
        total,
        (; ε = energies, wᴱ = weights, wᵏ = [1.0]),
        _DIAGNOSTIC_CORE.SCBAPhysicsMarkerPolicy(),
    )
    gamma_eigenvalues = eigvals(Hermitian(gamma))
    bounds = extrema(gamma_eigenvalues ./ step)
    quantiles = (markers.q10, markers.q50, markers.q90)
    marker_error = maximum(max(bounds[1]-q, q-bounds[2], 0.0) for q in quantiles)
    return Dict{String,Any}(
        "nodes"=>nodes,
        "phase_in_steps"=>phase,
        "window_eV"=>[lower, upper],
        "energy_step_eV"=>step,
        "gamma_over_step_bounds"=>collect(bounds),
        "sampled_gamma_over_step_quantiles"=>collect(quantiles),
        "sampled_underresolved_weight"=>markers.underresolved,
        "marker_status"=>String(markers.status),
        "marker_bound_violation"=>marker_error,
        "relative_matrix_integral_error"=>norm(integral-truth)/norm(truth),
        "quadrature_trace"=>real(tr(integral)),
        "analytic_trace"=>real(tr(truth)),
        "analytic_integral"=>_spectral_complex_record(truth),
    )
end

function _spectral_integral_checks()
    fixture = SPECTRAL_RESOLUTION_FIXTURE
    H = _spectral_resolution_hamiltonian()
    checks = Dict{String,Any}[]
    for linewidth in fixture.linewidth_scales_eV, phase in fixture.phases
        gamma = linewidth .* fixture.gamma_shape
        samples = [_spectral_resolution_sample(H, gamma, n, phase) for n in fixture.nodes]
        errors = [sample["relative_matrix_integral_error"] for sample in samples]
        row = _gate(
            "multilevel_integral_width_$(linewidth)_phase_$(phase)",
            last(errors),
            fixture.integral_relative_tolerance;
            expected = "final refined matrix quadrature agrees with independent finite-window logarithmic resolvent integral",
        )
        merge!(
            row,
            Dict(
                "units"=>"eV",
                "hamiltonian"=>_spectral_complex_record(H),
                "gamma"=>_spectral_complex_record(gamma),
                "gamma_scale_eV"=>linewidth,
                "noncommutation_relative"=>norm(H*gamma-gamma*H)/(norm(H)*norm(gamma)),
                "pole_full_linewidths_eV"=>-2imag.(eigvals(H-im*gamma/2)),
                "samples"=>samples,
                "scope"=>"manufactured_constant_causal_selfenergy_no_SCBA_certificate",
            ),
        )
        push!(checks, row)
        if linewidth == last(fixture.linewidth_scales_eV)
            push!(
                checks,
                Dict{String,Any}(
                    "name"=>"unresolved_multilevel_spectrum_detected_phase_$(phase)",
                    "value"=>first(errors),
                    "threshold"=>fixture.coarse_rejection_floor,
                    "comparison"=>"greater_or_equal",
                    "passed"=>isfinite(first(errors)) &&
                              first(errors)>=fixture.coarse_rejection_floor,
                    "expected"=>"coarse sampled quadrature is rejected; refining to the final mesh must independently meet the integral tolerance",
                    "coarse_nodes"=>first(fixture.nodes),
                    "coarse_marker_underresolved_weight"=>first(samples)["sampled_underresolved_weight"],
                    "fine_marker_underresolved_weight"=>last(samples)["sampled_underresolved_weight"],
                ),
            )
            marker_error = maximum(sample["marker_bound_violation"] for sample in samples)
            marker_mass_error = max(
                abs(first(samples)["sampled_underresolved_weight"]-1),
                abs(last(samples)["sampled_underresolved_weight"]),
            )
            push!(
                checks,
                _gate(
                    "known_gamma_marker_bounds_phase_$(phase)",
                    max(marker_error, marker_mass_error),
                    1e-10;
                    expected = "sampled modal Γ/ΔE lies within exact Rayleigh bounds; narrow coarse grid entirely unresolved, fine grid entirely resolved",
                ),
            )
        end
    end
    return checks
end

"""Independent full block assembly; never call finite_chain_green(return_full=true)."""
function _full_matrix_chain_oracle(energy, onsite, coupling, sr, sl, sg)
    blocks = length(onsite)
    count = size(first(onsite), 1)
    D = zeros(ComplexF64, blocks*count, blocks*count)
    L, G = similar(D), similar(D)
    fill!(L, 0)
    fill!(G, 0)
    for cell = 1:blocks
        rows = ((cell-1)*count+1):(cell*count)
        D[rows, rows] .= energy*I-onsite[cell]-sr[cell]
        L[rows, rows] .= sl[cell]
        G[rows, rows] .= sg[cell]
        if cell<blocks
            next_rows = (cell*count+1):((cell+1)*count)
            D[rows, next_rows] .= -coupling[cell]
            D[next_rows, rows] .= -coupling[cell]'
        end
    end
    R = inv(D)
    centre = cld(blocks, 2)
    rows = ((centre-1)*count+1):(centre*count)
    return (
        retarded = R[rows, rows],
        lesser = (R*L*R')[rows, rows],
        greater = (R*G*R')[rows, rows],
    )
end

function _multilevel_chain_checks()
    fixture = SPECTRAL_RESOLUTION_FIXTURE
    H = _spectral_resolution_hamiltonian()
    count = size(H, 1)
    eye = Matrix{ComplexF64}(I, count, count)
    cells = fixture.chain_cells
    onsite = [H+(j-cld(cells, 2))*fixture.chain_voltage_eV*eye for j = 1:cells]
    coupling_shape = ComplexF64[1 im/5 1/10; 1/7 4/5 im/8; -im/9 1/6 6/5]
    couplings = [fixture.chain_hopping_eV*(1+j/cells)*coupling_shape for j = 1:(cells-1)]
    sr, sl, sg = (Matrix{ComplexF64}[] for _ = 1:3)
    for j = 1:cells
        gamma = fixture.chain_linewidth_eV*(1+j/cells)*fixture.gamma_shape
        factor = Matrix(cholesky(Hermitian(gamma)).L)
        occupation = Diagonal(circshift(fixture.chain_occupations, j-1))
        push!(sr, -im*gamma/2)
        push!(sl, im*factor*occupation*factor')
        push!(sg, -im*factor*(eye-occupation)*factor')
    end
    checks = Dict{String,Any}[]
    for energy in fixture.chain_energies_eV
        truth = _full_matrix_chain_oracle(energy, onsite, couplings, sr, sl, sg)
        chain = _DIAGNOSTIC_CORE.finite_chain_green(
            energy,
            onsite,
            couplings;
            sigma_retarded = sr,
            sigma_lesser = sl,
            sigma_greater = sg,
        )
        for component in (:retarded, :lesser, :greater)
            exact = getproperty(truth, component)
            value = norm(getproperty(chain, component)-exact)/norm(exact)
            row = _gate(
                "multilevel_chain_$(component)_E_$(energy)",
                value,
                fixture.chain_relative_tolerance;
                expected = "cavity centre equals independently assembled full-chain inverse and Keldysh products",
            )
            merge!(
                row,
                Dict(
                    "energy_eV"=>energy,
                    "cells"=>cells,
                    "states_per_cell"=>count,
                    "onsite_eV"=>_spectral_complex_record.(onsite),
                    "couplings_eV"=>_spectral_complex_record.(couplings),
                    "sigma_retarded_eV"=>_spectral_complex_record.(sr),
                    "sigma_lesser_eV"=>_spectral_complex_record.(sl),
                    "sigma_greater_eV"=>_spectral_complex_record.(sg),
                    "oracle_central_block"=>_spectral_complex_record(exact),
                ),
            )
            push!(checks, row)
        end
    end
    return checks
end

function _operator_spectral_resolution_checks()
    return vcat(
        _spectral_integral_checks(),
        _multilevel_chain_checks(),
        _bounded_hilbert_checks(),
    )
end


"""Bounded Hilbert controls: distinguish algebraic FFT equivalence from quadrature."""
function _bounded_hilbert_checks()
    bn = _DIAGNOSTIC_CORE
    energy = collect(range(-1.0, 1.0; length = 129))
    weights = fill(2/128, 129)
    weights[[1, end]] ./= 2
    gamma = reshape(ComplexF64.(2 ./ (1 .+ energy .^ 2)), 129, 1, 1, 1)
    direct = bn.direct_hilbert_transform(gamma, energy, weights)
    fft = bn.fft_hilbert_transform(gamma, energy, weights)
    triangle = bn.product_integration_hilbert_transform(
        reshape(ComplexF64[0, 1, 0], 3, 1, 1, 1),
        [0.0, 1.0, 2.0],
        [0.5, 1.0, 0.5],
    )
    checks = Dict{String,Any}[
        _gate("Hilbert_FFT_equals_same_discrete_PV", norm(fft-direct)/norm(direct), 1e-12),
        _gate(
            "Hilbert_product_triangle_exact",
            norm(vec(real.(triangle))-[-log(2)/π, 0, log(2)/π]),
            1e-13,
        ),
    ]
    errors = Float64[]
    for n in (401, 801)
        e = collect(range(-20.0, 20.0; length = n))
        g = reshape(ComplexF64.(2 ./ (1 .+ e .^ 2)), n, 1, 1, 1)
        actual = bn.product_integration_hilbert_transform(g, e, fill(40/(n-1), n))
        mask = abs.(e) .<= 3
        push!(errors, maximum(abs, real.(vec(actual))[mask]-(e ./ (1 .+ e .^ 2))[mask]))
    end
    push!(
        checks,
        Dict(
            "name"=>"Hilbert_product_continuum_refinement",
            "value"=>last(errors),
            "threshold"=>5e-4,
            "passed"=>errors[2]<errors[1]/2 && errors[2]<5e-4,
            "errors"=>errors,
            "energy_nodes"=>[401, 801],
            "expected"=>"bounded Lorentzian continuum/window check; not a dense NE30721 allocation",
        ),
    )
    return checks
end
