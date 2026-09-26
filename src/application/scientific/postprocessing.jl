"""Nonuniform three-point derivative; every sample remains tied to its own solution.

Endpoints use a one-sided secant. Repeated voltage visits must be split into
branches before differentiation. No solver, interpolation, or implicit averaging
is involved.
"""
function differential_conductance(voltage::Vector{Float64}, current::Vector{Float64})
    length(voltage)==length(current) ||
        throw(DimensionMismatch("voltage/current lengths differ"))
    length(voltage)>=2 || throw(ArgumentError("dJ/dV requires at least two points"))
    all(isfinite, voltage) && all(isfinite, current) ||
        throw(ArgumentError("dJ/dV requires finite data"))
    steps=diff(voltage)
    all(>(0), steps) ||
        all(<(0), steps) ||
        throw(ArgumentError("dJ/dV requires one monotonic branch"))
    output=zeros(length(voltage))
    output[1]=(current[2]-current[1])/steps[1]
    output[end]=(current[end]-current[end-1])/steps[end]
    for i = 2:(length(voltage)-1)
        left=voltage[i]-voltage[i-1]
        right=voltage[i+1]-voltage[i]
        output[i]=-right/(left*(left+right))*current[i-1]+(right-left)/(left*right)*current[i]+left/(
            right*(left+right)
        )*current[i+1]
    end
    return output
end
