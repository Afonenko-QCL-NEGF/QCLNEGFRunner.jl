# Runner owns native storage and loads its required HDF5 dependency at import.
h5open(args...; kwargs...) = HDF5.h5open(args...; kwargs...)
attributes(args...; kwargs...) = HDF5.attributes(args...; kwargs...)
create_group(args...; kwargs...) = HDF5.create_group(args...; kwargs...)
read_attribute(args...; kwargs...) = HDF5.read_attribute(args...; kwargs...)

_hdf5_call(name::Symbol, args...; kwargs...) = getproperty(HDF5, name)(args...; kwargs...)
