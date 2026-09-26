function _study_replace_field(value, field::Symbol, replacement)
    fields = fieldnames(typeof(value))
    index = findfirst(==(field), fields)
    index === nothing && throw(ArgumentError("unknown field $field"))
    values = Any[getfield(value, name) for name in fields]
    values[index] = replacement
    return typeof(value)(values...)
end

function _study_replace_configuration(
    configuration::ResolvedRunConfiguration;
    physical = configuration.physical,
    scattering = configuration.scattering,
    algorithms = configuration.algorithms,
)
    production = QCLNEGFRunner._production_with_algorithms(configuration.production, algorithms)
    return ResolvedRunConfiguration(
        configuration.name,
        configuration.description,
        configuration.classification,
        physical,
        configuration.numerical,
        configuration.scales,
        scattering,
        configuration.solver,
        production,
        configuration.kernels,
        algorithms,
        configuration.execution,
        configuration.output,
        configuration.study,
        configuration.provenance,
        configuration.raw,
    )
end

function _study_changed_quantity(value)
    magnitude = Float64(ustrip(value))
    changed = iszero(magnitude) ? eps(Float64) : nextfloat(magnitude)
    return changed * Unitful.unit(value)
end

function _study_distinct_physical_value(physical::PhysicalParameters, field::Symbol)
    value = getfield(physical, field)
    if field === :layers
        return reverse(copy(value))
    elseif field === :interfaces
        changed = copy(value)
        changed[end] += 1.0e-15u"m"
        return changed
    elseif field === :ΔV_alloy
        return value === nothing ? 1.0u"eV" : _study_changed_quantity(value)
    elseif field === :Ω₀
        return value === nothing ? 1.0e-28u"m^3" : _study_changed_quantity(value)
    elseif value isa Unitful.AbstractQuantity
        return _study_changed_quantity(value)
    elseif field === :f_ion
        return value == 1.0 ? prevfloat(value) : nextfloat(value)
    elseif value isa AbstractFloat
        return nextfloat(value)
    elseif value isa Integer
        return value + one(value)
    end
    error("test has no distinct value for physical field $field")
end

function _study_distinct_layer_value(layer::Layer, field::Symbol)
    value = getfield(layer, field)
    if value isa Unitful.AbstractQuantity
        return _study_changed_quantity(value)
    elseif value isa Symbol
        return Symbol(String(value), "_signature_test")
    elseif value isa Bool
        return !value
    elseif value isa AbstractFloat
        return nextfloat(value)
    end
    error("test has no distinct value for layer field $field")
end
