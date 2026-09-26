module QCLNEGFRunnerPlotsExt

using QCLNEGFRunner
using CairoMakie
using Unitful

import QCLNEGFRunner:
    plot_band_profile,
    plot_spectral_map,
    plot_convergence,
    plot_current_spectrum,
    plot_conditioning,
    plot_reference_figure3a,
    plot_reference_iv,
    plot_reference_gain,
    plot_method_comparison,
    save_production_study_plots

_finite_residual(values) = [isfinite(v) && v > 0 ? v : NaN for v in values]

function _convergence_references!(axis)
    for (level, label) in ((1e-4, "10⁻⁴"), (1e-6, "10⁻⁶"), (1e-8, "10⁻⁸"))
        hlines!(
            axis,
            [level];
            color = :gray50,
            linestyle = :dash,
            linewidth = 1,
            label = "reference " * label,
        )
    end
    return axis
end

function plot_band_profile(solution::NEGFSolution)
    problem = solution.problem
    z_nm = problem.grids.x .* problem.scales.L₀_m .* 1e9
    Eref = QCLNEGFRunner._electronvolts(problem.physical.E_ref)
    Ec = problem.profiles.Eᶜ .* problem.scales.E₀_eV .+ Eref
    sp = QCLNEGFRunner._scaled_physics(problem.physical, problem.scales)
    field = -sp.F .* (problem.grids.x .- sp.z₀) .* problem.scales.E₀_eV
    UH = solution.Uᴴ .* problem.scales.E₀_eV
    potential = Ec .+ field .+ UH
    n = solution.n ./ problem.scales.L₀_m^3
    nscaled = n ./ max(maximum(n), eps())
    donors = problem.profiles.Nᴰ ./ problem.scales.L₀_m^3
    donors_scaled = donors ./ max(maximum(donors), eps())

    fig = Figure(size = (950, 560))
    ax = Axis(
        fig[1, 1],
        xlabel = "z (nm)",
        ylabel = "electron energy (eV)",
        title = "Band profile, Hartree energy and fixed basis",
    )
    lines!(ax, z_nm, potential; color = :black, linewidth = 2, label = "E_c+U_F+U_H")
    lines!(
        ax,
        z_nm,
        minimum(potential) .+ 0.08 .* nscaled;
        color = :dodgerblue,
        linewidth = 2,
        label = "scaled n(z)",
    )
    lines!(
        ax,
        z_nm,
        minimum(potential) .+ 0.08 .* donors_scaled;
        color = :firebrick,
        linewidth = 1.5,
        linestyle = :dash,
        label = "scaled Nᴰ(z)",
    )
    for a = 1:problem.numerical.N_b
        level = real(problem.basis.H₀[a, a]) * problem.scales.E₀_eV
        density = abs2.(problem.basis.χ[:, a])
        density ./= max(maximum(density), eps())
        lines!(ax, z_nm, level .+ 0.025 .* density; linewidth = 1.5, label = "|χ_$a|²")
    end
    axislegend(ax; position = :rb, framevisible = false)
    return fig
end

function plot_spectral_map(solution::NEGFSolution; occupied::Bool = false)
    maps = solution.observables[:spectral_maps]
    z_nm = ustrip.(u"nm", uconvert.(u"nm", maps.z))
    E_eV = ustrip.(u"eV", maps.E)
    data = occupied ? ustrip.(u"eV^-1*m^-3", maps.N) : ustrip.(u"eV^-1*m^-3", maps.A)
    fig = Figure(size = (900, 600))
    ax = Axis(
        fig[1, 1],
        xlabel = "z (nm)",
        ylabel = "E (eV)",
        title = occupied ? "Occupied spectral density" : "Local spectral density",
    )
    hm = heatmap!(
        ax,
        z_nm,
        E_eV,
        data;
        colormap = occupied ? :magma : :viridis,
        rasterize = true,
    )
    Colorbar(fig[1, 2], hm, label = "eV⁻¹ m⁻³")
    return fig
end

function plot_convergence(solution::NEGFSolution)
    fig = Figure(size = (980, 720))
    ax1 = Axis(
        fig[1, 1],
        xlabel = "SCBA iteration ν",
        ylabel = "residual",
        yscale = log10,
        title = "Inner fixed-point residuals",
    )
    h = solution.scba.history
    ν = [r.ν for r in h]
    for (label, values) in (
        ("r_D", [r.r_D for r in h]),
        ("r_A", [r.r_A for r in h]),
        ("r_K", [r.r_K for r in h]),
        ("r_Σ", [r.r_Σ for r in h]),
        ("r_λ", [r.r_λ for r in h]),
        ("r_round", [r.r_roundoff for r in h]),
        ("r_ΔJ", [r.r_Jchange for r in h]),
        ("r_pop", [r.r_population for r in h]),
    )
        lines!(ax1, ν, _finite_residual(values); label)
    end
    _convergence_references!(ax1)
    axislegend(ax1; position = :rt)

    ax2 = Axis(
        fig[2, 1],
        xlabel = "Poisson iteration μ",
        ylabel = "residual",
        yscale = log10,
        title = "Outer-loop residuals",
    )
    oh = solution.outer_history
    μ = [r.μ for r in oh]
    for (label, values) in (
        ("r_P", [r.r_P for r in oh]),
        ("r_U", [r.r_U for r in oh]),
        ("r_n", [r.r_n for r in oh]),
        ("r_neutral", [r.r_neutral for r in oh]),
        ("r_J", [r.r_J for r in oh]),
        ("r_ΔJ", [r.r_Jchange for r in oh]),
        ("r_pop", [r.r_population for r in oh]),
        ("|ζ|", [abs(r.ζ) for r in oh]),
    )
        lines!(ax2, μ, _finite_residual(values); label)
    end
    _convergence_references!(ax2)
    axislegend(ax2; position = :rt)
    Label(
        fig[3, 1],
        "Dashed lines: reference levels; acceptance criteria are separate. " *
        "Nonpositive or unavailable residuals are omitted on the logarithmic axis.",
        fontsize = 12,
        color = :gray35,
    )
    return fig
end

function plot_current_spectrum(solution::NEGFSolution)
    problem = solution.problem
    E =
        problem.grids.ε .* problem.scales.E₀_eV .+
        QCLNEGFRunner._electronvolts(problem.physical.E_ref)
    j = ustrip.(u"A/m^2/eV", solution.observables[:energy_resolved_current])
    fig = Figure(size = (880, 500))
    ax = Axis(
        fig[1, 1],
        xlabel = "E (eV)",
        ylabel = "j₊(E) (A m⁻² eV⁻¹)",
        title = "Energy-resolved outgoing electron-flow current",
    )
    lines!(ax, E, j; color = :darkorange, linewidth = 2)
    hlines!(ax, [0.0]; color = :gray, linestyle = :dash)
    return fig
end

function plot_conditioning(solution::NEGFSolution)
    problem = solution.problem
    E = problem.grids.ε .* problem.scales.E₀_eV
    k = problem.grids.κ ./ (problem.scales.L₀_m * 1e9)
    data = log10.(max.(solution.scba.green.condition_number, 1.0))
    fig = Figure(size = (900, 560))
    ax = Axis(
        fig[1, 1],
        xlabel = "E-E_ref (eV)",
        ylabel = "k∥ (nm⁻¹)",
        title = "log₁₀ κ₂(Dᴿ)",
    )
    hm = heatmap!(ax, E, k, data; colormap = :batlow, rasterize = true)
    Colorbar(fig[1, 2], hm, label = "log₁₀ κ₂")
    return fig
end

include("production_plots.jl")
include("expert_report_plots.jl")

end # module
