"""
    plot_method_comparison(comparison::ExpertComparison)

Plot current-density branches and pointwise relative current errors from an
[`ExpertComparison`](@ref). Circles denote an exact computational
implementation, diamonds a controlled numerical approximation, and triangles
a method that changes the physical model. Unconverged pairs are omitted from
the error panel rather than silently treated as valid accuracy samples.
"""
function plot_method_comparison(comparison::ExpertComparison)
    reference =
        only(filter(run -> run.descriptor.id === comparison.reference_id, comparison.runs))
    temperatures = sort!(
        unique(point.temperature_K for run in comparison.runs for point in run.points),
    )
    colors = (
        :black,
        :royalblue,
        :darkorange,
        :seagreen,
        :purple,
        :firebrick,
        :deepskyblue4,
        :goldenrod3,
    )

    figure = Figure(size = (1100, 720))
    current_axis = Axis(
        figure[1, 1],
        xlabel = "Vₚ (mV/period)",
        ylabel = "J (kA cm⁻²)",
        title = "Stored reference design current-density branches",
    )
    error_axis = Axis(
        figure[2, 1],
        xlabel = "Vₚ (mV/period)",
        ylabel = "|ΔJ| / |J_reference|",
        yscale = log10,
        title = "Converged pairs relative to reference",
    )

    sorted_runs = sort(comparison.runs; by = run -> String(run.descriptor.id))
    for (run_index, run) in pairs(sorted_runs)
        color = colors[mod1(run_index, length(colors))]
        marker = if run.descriptor.modifies_physics
            :utriangle
        elseif run.descriptor.algorithm_family === :controlled_approximation
            :diamond
        else
            :circle
        end
        for temperature in temperatures
            branch = sort(
                filter(point -> point.temperature_K == temperature, run.points);
                by = point -> point.voltage_per_period_V,
            )
            isempty(branch) && continue
            voltage = 1e3 .* getfield.(branch, :voltage_per_period_V)
            current = getfield.(branch, :current_A_per_m2) ./ 1e7
            valid_current =
                [point.converged ? value : NaN for (point, value) in zip(branch, current)]
            label = string(
                run.descriptor.id,
                ", ",
                compact_number(temperature; significant_digits = 4),
                " K",
            )
            lines!(
                current_axis,
                voltage,
                valid_current;
                color,
                linewidth = 2,
                linestyle = run.descriptor.id === reference.descriptor.id ? :solid : :dash,
                label,
            )
            scatter!(
                current_axis,
                voltage,
                current;
                color = [point.converged ? color : :transparent for point in branch],
                marker,
                strokecolor = [point.converged ? color : :red for point in branch],
                strokewidth = 1.2,
            )
        end

        run.descriptor.id === comparison.reference_id && continue
        rows = sort(
            filter(
                row ->
                    row.candidate_id === run.descriptor.id &&
                    row.metric === :current_A_per_m2 &&
                    row.reference_converged &&
                    row.candidate_converged &&
                    row.relative_error !== missing &&
                    row.relative_error > 0,
                comparison.rows,
            );
            by = row -> (row.temperature_K, row.voltage_per_period_V),
        )
        for temperature in temperatures
            branch = filter(row -> row.temperature_K == temperature, rows)
            isempty(branch) && continue
            scatterlines!(
                error_axis,
                1e3 .* getfield.(branch, :voltage_per_period_V),
                Float64[getfield(row, :relative_error) for row in branch];
                color,
                marker,
                linewidth = 1.7,
                label = string(
                    run.descriptor.id,
                    ", ",
                    compact_number(temperature; significant_digits = 4),
                    " K",
                ),
            )
        end
    end
    if !isempty(temperatures)
        axislegend(
            current_axis;
            position = :lt,
            framevisible = false,
            nbanks = max(1, cld(length(sorted_runs) * length(temperatures), 6)),
        )
    end
    if length(sorted_runs) > 1 && !isempty(temperatures)
        axislegend(
            error_axis;
            position = :lt,
            framevisible = false,
            nbanks = max(1, cld((length(sorted_runs) - 1) * length(temperatures), 6)),
        )
    end
    Label(
        figure[3, 1],
        "Circle: exact implementation; diamond: controlled numerical approximation; " *
        "triangle: modified physics; open/red edge: unconverged",
        fontsize = 12,
        color = :gray35,
    )
    return figure
end

"""Save PNG and vector PDF method-comparison figures for a study result."""
function save_production_study_plots(result::ProductionStudyResult)
    configuration = result.configuration
    reference = configuration.study.reference_profile
    reference === nothing &&
        throw(ArgumentError("study has no reference_profile for comparison plots"))
    runs = load_method_catalog(result.method_catalog)
    comparison = compare_method_runs(runs; reference_id = Symbol(reference))
    figure = plot_method_comparison(comparison)
    directory = joinpath(result.output_directory, configuration.output.report_directory)
    mkpath(directory)
    png = joinpath(directory, "method_comparison.png")
    pdf = joinpath(directory, "method_comparison.pdf")
    CairoMakie.save(png, figure; px_per_unit = 2)
    CairoMakie.save(pdf, figure)
    return (png = png, pdf = pdf)
end
