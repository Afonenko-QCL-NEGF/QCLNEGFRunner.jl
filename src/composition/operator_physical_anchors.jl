"""Independent truths exercised through production kernels, with saved receipts.

These small manufactured fixtures establish operator correctness. They do not
certify a self-consistent physical QCL point or fit experimental material data.
"""
const _DIAGNOSTIC_CORE=parentmodule(@__MODULE__)

function _diagnostic_numerics(n; changes...)
    return _DIAGNOSTIC_CORE.NumericalParameters(;
        (name=>get(changes, name, getfield(n, name)) for name in fieldnames(typeof(n)))...,
    )
end
function _operator_continuum_checks()
    bn=_DIAGNOSTIC_CORE
    checks=Dict{String,Any}[]
    z=0.2+0.3im
    coupling=0.04
    exact=only(
        filter(
            x->imag(x)<0,
            [(z-sqrt(z*z-4coupling))/(2coupling), (z+sqrt(z*z-4coupling))/(2coupling)],
        ),
    )
    family(value) = bn.SelfEnergyFamily(
        fill(ComplexF64(value), 1, 1, 1, 1),
        fill(-0.6im*imag(value), 1, 1, 1, 1),
        fill(1.4im*imag(value), 1, 1, 1, 1),
    )
    options=bn.ProductionOptions(worker_count = 1)
    for seed in (0.01, 0.1, 0.5)
        state=family(-im*seed)
        green=0.0im
        residual=Inf
        iterations=0
        for iteration = 1:1000
            G, _, _=bn._retarded_green_production(
                [real(z)],
                zeros(ComplexF64, 1, 1, 1),
                state.Σᴿ;
                η = imag(z),
                options,
            )
            green=only(G)
            candidate=family(coupling*green)
            residual=bn._selfenergy_residual(state, candidate)
            iterations=iteration
            residual<1e-11 && break
            bn._mix_family_production!(state, candidate, 0.6, options)
        end
        row=_gate("scalar_SCBA_causal_root_seed_$(seed)", abs(green-exact), 2e-10)
        merge!(
            row,
            Dict(
                "iterations"=>iterations,
                "unmixed_residual"=>residual,
                "real"=>real(green),
                "imag"=>imag(green),
                "oracle_real"=>real(exact),
                "oracle_imag"=>imag(exact),
            ),
        )
        push!(checks, row)
    end
    for phase in (0.0, 0.5)
        errors=Float64[]
        for nodes in (101, 201, 401)
            energy=collect(range(-0.6, 0.8; length = nodes))
            step=energy[2]-energy[1]
            centre=0.1+phase*step
            width=0.035
            G, _, _=bn._retarded_green_production(
                energy,
                reshape(ComplexF64[centre], 1, 1, 1),
                fill(-im*width, nodes, 1, 1, 1);
                options,
            )
            weights=fill(step, nodes)
            weights[[1, end]]./=2
            integral=dot(weights, real.(bn.spectral_function(G)[:, 1, 1, 1]))/(2π)
            exact=(atan((last(energy)-centre)/width)-atan((first(energy)-centre)/width))/π
            push!(errors, abs(integral-exact))
        end
        push!(
            checks,
            Dict(
                "name"=>"Lorentzian_grid_phase_$(phase)",
                "value"=>last(errors),
                "threshold"=>1e-6,
                "passed"=>errors[3]<errors[2]<errors[1] && errors[2]/errors[3]>3.5,
                "errors"=>errors,
                "expected"=>"second-order quadrature against finite-window analytic integral",
            ),
        )
    end
    # Continuum Dirichlet square well tested through the actual BDD operator.
    well_errors=Float64[]
    exact_levels=[n^2*π^2 for n = 1:3]
    for nodes in (31, 63, 127)
        spacing=1/(nodes+1)
        matrix=bn.build_bdd_hamiltonian(
            zeros(nodes),
            ones(nodes),
            spacing,
            1.0;
            boundary = :dirichlet,
        )
        levels=eigvals(Hermitian(matrix))[1:3]
        push!(well_errors, maximum(abs.((levels .- exact_levels) ./ exact_levels)))
    end
    push!(
        checks,
        Dict(
            "name"=>"BDD_continuum_square_well",
            "value"=>last(well_errors),
            "threshold"=>0.001,
            "passed"=>last(well_errors)<0.001 &&
                      well_errors[1]/well_errors[2]>3.9 &&
                      well_errors[2]/well_errors[3]>3.9,
            "errors"=>well_errors,
            "expected"=>"E_n=n^2*pi^2 in declared dimensionless Dirichlet well",
        ),
    )
    level=0.12
    gammaL=0.03
    gammaR=0.07
    energy=collect(range(-0.5, 0.6; length = 81))
    G, _, _=bn._retarded_green_production(
        energy,
        reshape(ComplexF64[level], 1, 1, 1),
        fill(-0.5im*(gammaL+gammaR), 81, 1, 1, 1);
        options,
    )
    exactG=1 ./ (energy .- level .+ 0.5im*(gammaL+gammaR))
    transmission=gammaL*gammaR .* abs2.(G[:, 1, 1, 1])
    exactT=gammaL*gammaR ./ ((energy .- level) .^ 2 .+ ((gammaL+gammaR)/2)^2)
    push!(
        checks,
        _gate("single_level_WBL_Green", maximum(abs.(G[:, 1, 1, 1] .- exactG)), 1e-12),
    )
    push!(
        checks,
        _gate(
            "single_level_WBL_transmission",
            maximum(abs.(transmission .- exactT)),
            1e-13,
        ),
    )
    physical=bn.reference_parameters(Tᴸ = 70u"K")
    scales=bn.ScaleSystem()
    errors=Float64[]
    for nodes in (32, 64, 128)
        numerical=_diagnostic_numerics(bn.tutorial_numerics(); N_z = nodes)
        grids=bn.build_grids(physical, numerical, scales)
        L=sum(grids.wˣ)
        epsilon=12.9
        exact=0.01 .* sin.(2π .* grids.x ./ L)
        donors=fill(1e3, nodes)
        profiles=bn.MaterialProfiles(
            zeros(nodes),
            fill(0.067, nodes),
            fill(0.067, nodes),
            fill(epsilon, nodes),
            donors,
            zeros(nodes),
            ones(Int, nodes),
        )
        density=donors .+ epsilon*(2π/L)^2/scales.λ_P .* exact
        solution, _, _, _=bn.solve_periodic_poisson(profiles, grids, scales, density)
        push!(errors, norm(solution-exact)/norm(exact))
    end
    push!(
        checks,
        Dict(
            "name"=>"continuum_periodic_Poisson",
            "value"=>last(errors),
            "threshold"=>0.001,
            "passed"=>last(errors)<0.001 &&
                      errors[1]/errors[2]>3.9 &&
                      errors[2]/errors[3]>3.9,
            "errors"=>errors,
            "expected"=>"second-order convergence to independently differentiated sinusoid",
        ),
    )
    return checks
end
function _operator_cavity_checks()
    bn=_DIAGNOSTIC_CORE
    checks=Dict{String,Any}[]
    hopping=0.7
    broadening=0.12
    occupation=0.37
    for energy in (-2.0, 0.0, 0.5, 2.0)
        z=energy+im*broadening
        surface=bn.chain_surface_green(z, hopping)
        exact=inv(z-2hopping^2*surface)
        count=201
        chain=bn.finite_chain_green(
            energy,
            [zeros(ComplexF64, 1, 1) for _ = 1:count],
            [fill(ComplexF64(hopping), 1, 1) for _ = 1:(count-1)];
            sigma_retarded = [fill(-im*broadening, 1, 1) for _ = 1:count],
            sigma_lesser = [fill(2im*broadening*occupation, 1, 1) for _ = 1:count],
        )
        push!(
            checks,
            _gate(
                "surface_Dyson_E_$(energy)",
                abs(surface-inv(z-hopping^2*surface)),
                1e-13,
            ),
        )
        for (kind, expected) in (
            (:retarded, exact),
            (:lesser, -2im*occupation*imag(exact)),
            (:greater, 2im*(1-occupation)*imag(exact)),
        )
            push!(
                checks,
                _gate(
                    "finite_chain_$(kind)_E_$(energy)",
                    abs(only(getproperty(chain, kind))-expected)/abs(expected),
                    2e-6,
                ),
            )
        end
    end
    # The legacy bulk-feedback is a different closure. Its mismatch is an
    # expected model observation, never a hidden correction of the exact oracle.
    z=0.1im
    exact=inv(z-2bn.chain_surface_green(z, 1.0))
    feedback=(z-sqrt(z*z-8))/(4)
    relative=abs(feedback-exact)/abs(exact)
    push!(
        checks,
        Dict(
            "name"=>"bulk_feedback_model_distinction",
            "value"=>relative,
            "threshold"=>1e-12,
            "passed"=>abs(relative-0.3668024761196107)<=1e-9,
            "expected"=>"declared legacy closure differs from exact chain by about36.68%; no claim of physical equivalence",
            "bulk_imag"=>imag(feedback),
            "exact_imag"=>imag(exact),
        ),
    )
    return checks
end

function _diagnostic_lo_equilibrium(
    nodes,
    steps_per_phonon,
    algorithm;
    qz_nodes = 81,
    angular_nodes = 32,
)
    physical=_DIAGNOSTIC_CORE.reference_parameters(Tᴸ = 70u"K", V_period = 0u"mV")
    phonon=ustrip(u"eV", physical.ħωᴸᴼ)
    step=phonon/steps_per_phonon
    half_window=(nodes-1)*step/2
    original=_DIAGNOSTIC_CORE.tutorial_numerics()
    changes=(;
        N_b = 2,
        N_k = 3,
        N_E = nodes,
        N_qz = qz_nodes,
        N_φ = angular_nodes,
        qz_max = 10.0u"nm^-1",
        E_min = -half_window*u"eV",
        E_max = half_window*u"eV",
    )
    numerical=_DIAGNOSTIC_CORE.NumericalParameters(;
        (
            name=>hasproperty(changes, name) ? getproperty(changes, name) :
                  getfield(original, name) for
            name in fieldnames(_DIAGNOSTIC_CORE.NumericalParameters)
        )...,
    )
    algorithms=_DIAGNOSTIC_CORE.AlgorithmOptions(energy_shift = algorithm)
    options=_DIAGNOSTIC_CORE.ProductionOptions(algorithms = algorithms, worker_count = 1)
    built=_DIAGNOSTIC_CORE.build_configured_scattering_problem(;
        physical,
        numerical,
        scales = _DIAGNOSTIC_CORE.ScaleSystem(),
        scattering = _DIAGNOSTIC_CORE.ScatteringOptions(
            LO = true,
            acoustic = false,
            impurity = false,
            IFR = false,
            alloy = false,
        ),
        algorithms,
        kernel_options = _DIAGNOSTIC_CORE.ProductionKernelOptions(),
    )
    problem=built.problem
    g=problem.grids
    s=problem.scales
    shape=(nodes, numerical.N_k, numerical.N_b, numerical.N_b)
    GR=zeros(ComplexF64, shape)
    less=similar(GR)
    greater=similar(GR)
    A=similar(GR)
    fill!(less, 0)
    fill!(greater, 0)
    fill!(A, 0)
    kBT=_DIAGNOSTIC_CORE._electronvolts(_DIAGNOSTIC_CORE.CODATA.kᴮₑᵥ*physical.Tᴸ)/s.E₀_eV
    f=[_DIAGNOSTIC_CORE._fermi(e, 0.0, kBT) for e in g.ε]
    # A positive smooth spectral fixture isolates the actual LO scattering
    # operator from a separate Dyson fixed point. The broad window suppresses
    # exterior-tail contamination, while the fractional shifts remain real.
    for e = 1:nodes, m = 1:numerical.N_k, a = 1:numerical.N_b
        spectral=exp(-((g.ε[e]*s.E₀_eV)/0.035)^2)*(1+0.1m+0.05a)
        A[e, m, a, a]=spectral
        GR[e, m, a, a]=-0.5im*spectral
        less[e, m, a, a]=im*f[e]*spectral
        greater[e, m, a, a]=-im*(1-f[e])*spectral
    end
    green=_DIAGNOSTIC_CORE.GreenState(
        GR,
        less,
        greater,
        A,
        ones(nodes, numerical.N_k),
        ones(nodes, numerical.N_k),
    )
    cache=build_production_cache(problem; options)
    lesser, greater=_DIAGNOSTIC_CORE._production_lo_contraction(
        cache.kernels[:LO],
        green,
        problem,
        cache,
        problem.kernels.qᴷ[:LO],
        options,
    )
    kms=copy(lesser)
    number, energy, event_scale=0.0, 0.0, 0.0
    for e = 1:nodes, m = 1:numerical.N_k
        kms[e, m, :, :].-=f[e] .* (lesser[e, m, :, :] .- greater[e, m, :, :])
        incoming=real(
            tr(Matrix(view(lesser, e, m, :, :))*Matrix(view(green.Gᵍ, e, m, :, :))),
        )
        outgoing=real(
            tr(Matrix(view(greater, e, m, :, :))*Matrix(view(green.Gˡ, e, m, :, :))),
        )
        weight=g.wᴱ[e]*g.wᵏ[m]
        number+=weight*(incoming-outgoing)
        energy+=weight*g.ε[e]*(incoming-outgoing)
        event_scale+=weight*(abs(incoming)+abs(outgoing))
    end
    kms_residual=norm(kms)/max(norm(lesser), norm(greater))
    delta=phonon/s.E₀_eV
    return (;
        kms = kms_residual,
        number = abs(number)/event_scale,
        energy = abs(energy)/(delta*event_scale),
        kernel = problem.kernels.qᴷ[:LO] .* problem.kernels.K[:LO],
        lesser,
        greater,
    )
end

function _operator_lo_equilibrium_checks()
    checks=Dict{String,Any}[]
    for algorithm in (:sparse_plan, :conservative_pair)
        integer=_diagnostic_lo_equilibrium(129, 8.0, algorithm)
        for name in (:kms, :number, :energy)
            push!(
                checks,
                _gate("LO_integer_$(algorithm)_$(name)", getproperty(integer, name), 1e-12),
            )
        end
        values=[
            _diagnostic_lo_equilibrium(n, steps, algorithm) for
            (n, steps) in ((129, 8.3), (257, 16.6), (513, 33.2))
        ]
        for name in (:kms, :energy)
            errors=[getproperty(v, name) for v in values]
            push!(
                checks,
                Dict(
                    "name"=>"LO_fractional_refinement_$(algorithm)_$(name)",
                    "value"=>last(errors),
                    "threshold"=>first(errors),
                    "passed"=>errors[3]<errors[2]<errors[1],
                    "errors"=>errors,
                    "expected"=>"actual microscopic LO contraction approaches equilibrium detailed balance under energy refinement",
                ),
            )
        end
        push!(
            checks,
            _gate(
                "LO_fractional_particle_balance_$(algorithm)",
                maximum(v.number for v in values),
                1e-10,
            ),
        )
    end
    append!(checks, _operator_lo_quadrature_checks())
    return checks
end
function _structure_spectrum_checks(configuration, point)
    bn=_DIAGNOSTIC_CORE
    raw=deepcopy(configuration.raw)
    if point!==nothing
        raw["physical"]["voltage_per_period"]="$(point.voltage_per_period_V) V"
        raw["physical"]["lattice_temperature"]="$(point.temperature_K) K"
        raw["physical"]["lo_temperature"]="$(point.temperature_K) K"
    end
    c=_resolve_configuration(raw, configuration.provenance)
    grids=bn.build_grids(c.physical, c.numerical, c.scales)
    profiles=bn.build_profiles(c.physical, c.numerical, c.scales, grids)
    basis=bn.build_basis(
        c.physical,
        c.numerical,
        c.scales,
        grids,
        profiles;
        localization = c.algorithms.localization,
    )
    projected=bn.project_hamiltonians(
        basis,
        grids,
        profiles,
        c.physical,
        c.scales,
        zeros(length(grids.x)),
    )
    limits=bn.QCLNumerics._STRUCTURAL_VALIDATION_LIMITS
    row=_gate("structure_basis_orthonormal", basis.r_orth, limits[:basis_orthogonality])
    merge!(
        row,
        Dict(
            "scope"=>"single-electron_basis_no_scattering_no_stationary_certificate",
            "energies_eV"=>eigvals(Hermitian(Matrix(view(projected, 1, :, :)))) .*
                           c.scales.E₀_eV,
            "zero_field_basis_energies_eV"=>eigvals(Hermitian(basis.H₀)) .* c.scales.E₀_eV,
            "hartree_eV"=>0.0,
            "window_energies_eV"=>basis.window_eigenvalues .* c.scales.E₀_eV,
            "centres_nm"=>basis.centres .* c.scales.L₀_m .* 1e9,
            "spreads_nm"=>basis.spreads .* c.scales.L₀_m .* 1e9,
            "period_nm"=>ustrip(u"nm", bn.period_length(c.physical)),
            "basis_overlap_condition"=>basis.κ_overlap,
            "basis_states"=>c.numerical.N_b,
            "basis_periods"=>c.numerical.P_basis,
            "basis_eigen_residual"=>basis.r_eigen,
            "translation_residual"=>basis.r_translation,
            "translation_nearest_residual"=>basis.r_translation_nearest,
            "translation_two_pairs_residual"=>basis.r_translation_two_pairs,
            "voltage_V"=>point===nothing ? nothing : point.voltage_per_period_V,
            "temperature_K"=>point===nothing ? nothing : point.temperature_K,
        ),
    )
    # Reuse the production preflight metrics and thresholds. An orthonormal
    # truncated basis alone does not prove that its translated periods agree.
    checks = [
        row,
        _gate("structure_basis_eigen", basis.r_eigen, limits[:basis_eigen]),
        _gate(
            "structure_Hermitian_H0",
            maximum(
                bn.QCLNumerics._relative_norm(
                    Matrix(view(projected, m, :, :)),
                    Matrix(view(projected, m, :, :))',
                ) for m in axes(projected, 1)
            ),
            limits[:hamiltonian_hermiticity],
        ),
        _gate(
            "structure_coupling_adjoint",
            bn.QCLNumerics._relative_norm(basis.T₋, basis.T₊'),
            limits[:T_adjoint],
        ),
    ]
    if basis.localization === :pzp
        append!(
            checks,
            [
                _gate(
                    "structure_translation",
                    basis.r_translation,
                    bn.QCLNumerics._PZP_TRANSLATION_LIMIT,
                ),
                _gate(
                    "structure_translation_nearest",
                    basis.r_translation_nearest,
                    bn.QCLNumerics._PZP_TRANSLATION_LIMIT,
                ),
                _gate(
                    "structure_translation_two_pairs",
                    basis.r_translation_two_pairs,
                    c.numerical.P_basis >= 3 ? bn.QCLNumerics._PZP_TWO_PAIR_LIMIT :
                    bn.QCLNumerics._PZP_TRANSLATION_LIMIT,
                ),
            ],
        )
    end
    return checks
end


"""Actual LO tensor and collision-map quadrature on one manufactured equilibrium G."""
function _operator_lo_quadrature_checks()
    counts = (81, 161, 321, 641)
    samples =
        [_diagnostic_lo_equilibrium(65, 4.0, :sparse_plan; qz_nodes = n) for n in counts]
    reference = last(samples)
    kernel_errors = [
        norm(sample.kernel-reference.kernel)/norm(reference.kernel) for
        sample in samples[1:3]
    ]
    map_errors = [
        norm(sample.lesser-reference.lesser)/norm(reference.lesser) for
        sample in samples[1:3]
    ]
    # Independent finite-interval integral. It does not replace the real form factors.
    exact = 2atan(10/0.2)/0.2
    scalar_errors = Float64[]
    for n in counts[1:3]
        q = collect(range(-10.0, 10.0; length = n))
        w = fill(q[2]-q[1], n)
        w[[1, end]] ./= 2
        integral = sum(w ./ (q .^ 2 .+ 0.2^2))
        push!(scalar_errors, abs(integral-exact)/exact)
    end
    checks = Dict{String,Any}[
        Dict(
            "name"=>"LO_qz_actual_kernel_refinement",
            "value"=>last(kernel_errors),
            "threshold"=>first(kernel_errors),
            "passed"=>all(isfinite, kernel_errors) && kernel_errors[3] < kernel_errors[1],
            "qz_nodes"=>collect(counts),
            "relative_errors_to_641"=>kernel_errors,
            "expected"=>"measured tensor convergence versus actual 641-node form-factor tensor; no universal accuracy certificate",
            "physical_model"=>"bulk_LO_screened_denominator_1_over_Q2_plus_qs2",
        ),
        Dict(
            "name"=>"LO_qz_frozen_map_refinement",
            "value"=>last(map_errors),
            "threshold"=>first(map_errors),
            "passed"=>all(isfinite, map_errors) && map_errors[3] < map_errors[1],
            "qz_nodes"=>collect(counts),
            "relative_errors_to_641"=>map_errors,
            "expected"=>"same manufactured equilibrium Green state, raw actual LO lesser map",
        ),
        Dict(
            "name"=>"LO_qz_scalar_finite_integral",
            "value"=>last(scalar_errors),
            "threshold"=>1e-7,
            "passed"=>last(scalar_errors)<1e-7,
            "relative_errors"=>scalar_errors,
            "expected"=>"independent integral 2*atan(qmax/qs)/qs, form factor one, qparallel zero",
        ),
    ]
    angular64 = _diagnostic_lo_equilibrium(
        65,
        4.0,
        :sparse_plan;
        qz_nodes = 321,
        angular_nodes = 64,
    )
    angular_defect = norm(samples[3].kernel-angular64.kernel)/norm(angular64.kernel)
    push!(
        checks,
        Dict(
            "name"=>"LO_actual_angular_32_64_comparison",
            "value"=>angular_defect,
            "threshold"=>nothing,
            "passed"=>isfinite(angular_defect),
            "expected"=>"finite measured discretization difference only; not an angular convergence certificate",
        ),
    )
    return checks
end
