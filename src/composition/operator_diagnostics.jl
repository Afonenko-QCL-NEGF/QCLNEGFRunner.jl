# Manufactured oracle coordinates are dimensionless and unrelated to solver mixing.
const OPERATOR_DIAGNOSTIC_FIXTURE = (
    lorentzian_linewidth = 0.02,
    lorentzian_windows = [0.2, 2.0, 20.0],
    hopping = 0.3,
    occupation = 0.37,
)

"""Independent small exact/analytic oracles recorded as campaign results."""
function run_operator_diagnostics(
    operation::Symbol,
    configuration = nothing;
    point = nothing,
)
    if operation===:structure_spectrum
        configuration===nothing &&
            throw(ArgumentError("structure spectrum requires resolved configuration"))
        return _structure_spectrum_checks(configuration, point)
    end
    operations=Dict{Symbol,Function}(
        :operator_algebra=>_operator_algebra_checks,
        :operator_metrics=>_operator_metric_checks,
        :operator_representation=>_operator_representation_checks,
        :operator_continuum=>_operator_continuum_checks,
        :operator_cavity=>_operator_cavity_checks,
        :operator_lo_equilibrium=>_operator_lo_equilibrium_checks,
        :operator_spectral_resolution=>_operator_spectral_resolution_checks,
    )
    haskey(operations, operation) || throw(ArgumentError("unknown operator diagnostic"))
    return operations[operation]()
end
_gate(name, value, tolerance; expected = "zero") = Dict{String,Any}(
    "name"=>name,
    "value"=>value,
    "threshold"=>tolerance,
    "passed"=>isfinite(value) && abs(value)<=tolerance,
    "expected"=>expected,
)
function _operator_algebra_checks()
    hopping=OPERATOR_DIAGNOSTIC_FIXTURE.hopping
    z=ComplexF64(0.21, 0.07)
    h=Matrix(SymTridiagonal(zeros(3), fill(hopping, 2)))
    green=inv(z*I-h)
    # The central diagonal element follows exactly from the 3-site determinant.
    exact=z/(z*z-2hopping*hopping)
    spectral=im*(green-green')
    occupation=OPERATOR_DIAGNOSTIC_FIXTURE.occupation
    lesser=im*occupation*spectral
    greater=-im*(1-occupation)*spectral
    gamma=2imag(z)*Matrix{ComplexF64}(I, 3, 3)
    sigma_l=im*occupation*gamma
    sigma_g=-im*(1-occupation)*gamma
    current=real(tr(sigma_g*lesser-sigma_l*greater))
    return [
        _gate("three_site_central_green", abs(green[2, 2]-exact), 1e-13),
        _gate("equilibrium_Keldysh", norm(lesser-green*sigma_l*green'), 1e-12),
        _gate("equilibrium_zero_collision_current", current, 1e-13),
        _gate("spectral_identity", norm(spectral-green*gamma*green'), 1e-12),
    ]
end
function _operator_metric_checks()
    norm=1e-16
    defect=1e-17
    budget=psd_error_budget(norm, 2; construction_scale = norm)
    significant=(defect-budget)/norm
    tolerance=1e-10
    gamma=OPERATOR_DIAGNOSTIC_FIXTURE.lorentzian_linewidth
    integral(window) = 4atan(window/gamma) # integral of 2 gamma/(E²+gamma²), [-window,window]
    windows=OPERATOR_DIAGNOSTIC_FIXTURE.lorentzian_windows
    errors=abs.(integral.(windows) ./ (2π) .- 1)
    return [
        Dict{String,Any}(
            "name"=>"significant_negative_scaled_block",
            "value"=>significant,
            "threshold"=>tolerance,
            "passed"=>significant>tolerance,
            "expected"=>"rejected negative eigenvalue -1e-17 at matrix scale 1e-16",
            "matrix"=>[[-defect, 0.0], [0.0, norm]],
            "backward_error"=>budget,
        ),
        _gate(
            "PSD_noise_budget_scale_covariance",
            abs(psd_error_budget(1.0, 2; construction_scale = 1.0)*norm-budget),
            1e-40,
        ),
        Dict{String,Any}(
            "name"=>"Lorentzian_window_sum_rule",
            "value"=>last(errors),
            "threshold"=>1e-3,
            "passed"=>all(diff(errors) .< 0) && last(errors)<1e-3,
            "windows"=>windows,
            "relative_errors"=>errors,
            "expected"=>"finite-window sum approaches one with increasing window",
        ),
    ]
end
function _operator_representation_checks()
    h=ComplexF64[0.2 0.1im 0.05; -0.1im 0.4 0.02; 0.05 0.02 0.7]
    density=ComplexF64[0.4 0.03im 0; -0.03im 0.35 0.01; 0 0.01 0.25]
    position=Diagonal([0.0, 1.0, 2.0])
    phase=cis(2π/3)
    unitary=ComplexF64[1 1 1; 1 phase phase^2; 1 phase^2 phase]/sqrt(3)
    current=im*tr((h*position-position*h)*density)
    transformed=unitary'*h*unitary
    rho=unitary'*density*unitary
    z=unitary'*position*unitary
    return [
        _gate("unitary_basis_identity", norm(unitary'*unitary-I), 1e-14),
        _gate("same_space_density_trace", abs(tr(rho)-tr(density)), 1e-14),
        _gate(
            "same_space_current_invariance",
            abs(im*tr((transformed*z-z*transformed)*rho)-current),
            1e-14,
        ),
        _gate(
            "same_space_spectrum_invariance",
            norm(eigvals(Hermitian(h))-eigvals(Hermitian(transformed))),
            1e-14,
        ),
    ]
end

include("operator_physical_anchors.jl")
include("operator_spectral_resolution.jl")
