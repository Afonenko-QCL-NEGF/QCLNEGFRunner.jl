function _require_final_solution(solution::NEGFSolution, require_converged::Bool)
    require_converged &&
        !solution.converged &&
        throw(
            ArgumentError(
                "final reference design plot requires a converged solution; " *
                "received status=$(solution.status)",
            ),
        )
    return solution
end

"""
    plot_reference_figure3a(solution; require_converged=false, periods=-1:1)

Plot the quantities that the stationary model can place next to QCL
Fig. 3(a): tilted conduction band, effective-state envelopes and occupied
spectral density.  Neighboring periods are reconstructed with the exact
field-periodic energy offset.  This function does not copy the published
figure and does not plot experimental data. Finite unaccepted states render
with an explicit quality/status marker by default; `require_converged=true`
requests strict rejection. Potential, effective-state envelopes and n(E,z)
use the same saved-snapshot projection and declared basis/units as FigureData.

See [the reference design structure passport](@ref theory-reference2019),
[Field-periodic closure](@ref theory-periodicity), and
[production plots](@ref theory-production).
"""
function plot_reference_figure3a(
    solution::NEGFSolution;
    require_converged::Bool = false,
    periods = -1:1,
    energy_limits_meV = (-50.0, 200.0),
    position_limits_nm = (-10.0, 35.0),
)
    _require_final_solution(solution, require_converged)
    problem = solution.problem
    # Project the same typed state, basis, energy origin and units as native
    # analysis. Rendering never chooses a different state or recomputes a solve.
    map = spatial_energy_density(problem, solution.scba.green.Gˡ)
    z = 1e9 .* map.z_m
    energy = 1e3 .* map.energy_eV
    occupied = permutedims(map.n_per_eV_m3) .* 1e-30 # m⁻³/eV -> nm⁻³/meV
    potential =
        problem.profiles.Eᶜ .* problem.scales.E₀_eV .+
        QCLNEGFRunner._electronvolts(problem.physical.E_ref) .-
        QCLNEGFRunner._volts_per_metre(problem.physical.F_bias) .*
        (map.z_m .- QCLNEGFRunner._metres(problem.physical.z₀)) .+
        solution.Uᴴ .* problem.scales.E₀_eV
    all(isfinite, occupied) && all(isfinite, potential) ||
        throw(ArgumentError("reference design state plot needs finite density and potential arrays"))
    Lp_nm = Float64(ustrip(u"nm", QCLNEGFRunner.period_length(problem.physical)))
    Vp_meV = 1e-6 * QCLNEGFRunner._volts_per_metre(problem.physical.F_bias) * Lp_nm
    band_meV = 1e3 .* potential
    levels = effective_levels(problem, solution.Uᴴ)
    level_meV = Float64.(ustrip.(u"meV", levels.E))
    envelopes = abs2.(problem.basis.χ * levels.eigenvectors)
    for a in axes(envelopes, 2)
        maximum(view(envelopes, :, a)) > 0 &&
            (view(envelopes, :, a) ./= maximum(view(envelopes, :, a)))
    end

    fig = Figure(size = (980, 650))
    ax = Axis(
        fig[1, 1],
        xlabel = "z (nm)",
        ylabel = "electron energy (meV)",
        title = "reference design stationary NEGF — $(solution_quality(solution)): $(solution.status)",
    )
    color_min = min(0.0, minimum(occupied))
    color_max = max(maximum(occupied), eps(Float64))
    heat = nothing
    palette = (:firebrick, :royalblue, :seagreen, :darkorange, :purple)
    for q in periods
        heat = heatmap!(
            ax,
            z .+ q * Lp_nm,
            energy .- q * Vp_meV,
            occupied;
            colormap = :grays,
            colorrange = (color_min, color_max),
            rasterize = true,
        )
        lines!(ax, z .+ q * Lp_nm, band_meV .- q * Vp_meV; color = :black, linewidth = 2)
        for a in axes(envelopes, 2)
            lines!(
                ax,
                z .+ q * Lp_nm,
                level_meV[a] - q * Vp_meV .+ 8 .* envelopes[:, a];
                color = palette[mod1(a, length(palette))],
                linewidth = 1.5,
            )
        end
    end
    xlims!(ax, position_limits_nm...)
    ylims!(ax, energy_limits_meV...)
    Colorbar(fig[1, 2], heat; label = "n(E,z) (meV⁻¹ nm⁻³)")
    Label(
        fig[2, 1:2],
        "Basis: effective_hamiltonian_k0; energy origin: declared E_ref. " *
        (
            solution.converged ? "Strictly accepted state" :
            "Unaccepted finite state; $(solution.status)"
        ) *
        ". Envelope height is a display scale; colour is n(E,z).",
        fontsize = 12,
        color = solution.converged ? :gray35 : :firebrick,
    )
    return fig
end

"""
    plot_reference_iv(result; periods, ridge_width, cavity_length)

Plot the calculated current-density curve against voltage per period and its
geometry-derived device-level conversion.  The right panel excludes contact
drop, series resistance and electric-field domains and is therefore labelled
as a derived active-region scale rather than a measured terminal I--V.

See [Observables and balances](@ref theory-observables),
[debug/final visualization](@ref theory-visualization), and
[production plots](@ref theory-production).
"""
function plot_reference_iv(
    result::ProductionSweepResult;
    periods::Integer,
    ridge_width,
    cavity_length,
)
    periods > 0 || throw(ArgumentError("periods must be positive"))
    area_cm2 = Float64(ustrip(u"cm^2", uconvert(u"cm^2", ridge_width * cavity_length)))
    temperatures = sort!(unique(record.temperature_K for record in result.records))
    fig = Figure(size = (1080, 470))
    ax_density = Axis(
        fig[1, 1],
        xlabel = "Vₚ (mV/period)",
        ylabel = "electron-flow J (kA cm⁻²)",
        title = "Calculated periodic transport",
    )
    ax_device = Axis(
        fig[1, 2],
        xlabel = "Nₚ Vₚ (V)",
        ylabel = "I (A)",
        title = "Active-region geometry conversion",
    )
    colors = (:royalblue, :darkorange, :seagreen, :purple, :firebrick, :deepskyblue4)
    for (i, temperature) in pairs(temperatures)
        branch = sort(
            [record for record in result.records if record.temperature_K == temperature];
            by = record -> record.voltage_per_period_V,
        )
        voltage_mV = 1e3 .* [record.voltage_per_period_V for record in branch]
        density = [record.current_A_per_m2 / 1e7 for record in branch]
        device_voltage = periods .* [record.voltage_per_period_V for record in branch]
        current = [record.current_A_per_m2 * area_cm2 / 1e4 for record in branch]
        density_line =
            [record.converged ? value : NaN for (record, value) in zip(branch, density)]
        current_line =
            [record.converged ? value : NaN for (record, value) in zip(branch, current)]
        label = "$(round(temperature; digits=1)) K"
        color = colors[mod1(i, length(colors))]
        lines!(ax_density, voltage_mV, density_line; color, linewidth = 2, label)
        scatter!(
            ax_density,
            voltage_mV,
            density;
            color = [record.converged ? color : :transparent for record in branch],
            strokecolor = [record.converged ? color : :red for record in branch],
            strokewidth = 1.5,
        )
        lines!(ax_device, device_voltage, current_line; color, linewidth = 2, label)
        scatter!(
            ax_device,
            device_voltage,
            current;
            color = [record.converged ? color : :transparent for record in branch],
            strokecolor = [record.converged ? color : :red for record in branch],
            strokewidth = 1.5,
        )
    end
    axislegend(ax_density; position = :lt, framevisible = false)
    Label(
        fig[2, 1:2],
        "Open red markers are unconverged; device conversion omits contacts and domains",
        fontsize = 12,
        color = :gray35,
    )
    return fig
end

"""
Plot trusted and edge-contaminated parts of a bare-bubble gain spectrum.
The vertical guide is derived from the computed maximum inside the trusted
window; no published transition energy is hard-coded into the plot.

See [Optical response](@ref theory-optical-response),
[debug/final visualization](@ref theory-visualization), and
[production plots](@ref theory-production).
"""
function plot_reference_gain(response::OpticalResponse)
    energy = Float64.(ustrip.(u"meV", response.photon_energy))
    gain = Float64.(ustrip.(u"cm^-1", response.gain))
    trusted = findall(response.trusted)
    untrusted = findall(.!response.trusted)
    fig = Figure(size = (900, 520))
    ax = Axis(
        fig[1, 1],
        xlabel = "ħω (meV)",
        ylabel = "material gain (cm⁻¹)",
        title = "reference design length-gauge bare-bubble diagnostic",
    )
    lines!(
        ax,
        energy,
        gain;
        color = :gray70,
        linestyle = :dash,
        label = "all returned points",
    )
    isempty(trusted) || scatterlines!(
        ax,
        energy[trusted],
        gain[trusted];
        color = :darkorange,
        linewidth = 2,
        markersize = 7,
        label = "trusted window",
    )
    isempty(untrusted) || scatter!(
        ax,
        energy[untrusted],
        gain[untrusted];
        color = :transparent,
        strokecolor = :red,
        strokewidth = 1.5,
        label = "edge contaminated",
    )
    hlines!(ax, [0.0]; color = :black, linewidth = 1)
    if !isempty(trusted)
        peak_index = trusted[argmax(gain[trusted])]
        peak_energy = energy[peak_index]
        vlines!(
            ax,
            [peak_energy];
            color = :royalblue,
            linestyle = :dot,
            label = "computed trusted peak: $(round(peak_energy; sigdigits=4)) meV",
        )
    end
    axislegend(ax; position = :rb, framevisible = false)
    Label(
        fig[2, 1],
        "No vertex corrections or e–e self-energy: use for peak/trends, not absolute published gain",
        fontsize = 12,
        color = :gray35,
    )
    return fig
end
