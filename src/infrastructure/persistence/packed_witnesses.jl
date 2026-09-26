"""Lossless packed PSD evidence. Indices/offsets are zero based; values are external C order."""
const _PACKED_PSD_SCHEMA="qcl-negf-psd-selected-packed-v2"
const _PACKED_PSD_COLUMNS=(
    "record_sequence",
    "record_attributes_json",
    "group_metadata_json",
    "record_group_metadata_index",
    "dataset_metadata_json",
    "payload_record_index",
    "payload_metadata_index",
    "payload_offsets",
    "payload_values",
)

function _require_packed_witness_schema(table)
    haskey(attributes(table), "schema") || throw(
        ArgumentError(
            "selected PSD witnesses require the current packed schema; legacy groups are unsupported",
        ),
    )
    String(read_attribute(table, "schema"))==_PACKED_PSD_SCHEMA ||
        throw(ArgumentError("unsupported selected PSD witness schema"))
    Set(keys(table))==Set(_PACKED_PSD_COLUMNS) ||
        throw(ArgumentError("packed PSD columns differ from the native v4 contract"))
    return nothing
end

function _finite_metadata(value)
    value isa Real && return isfinite(value)
    value isa AbstractDict && return all(_finite_metadata, values(value))
    (value isa AbstractArray || value isa Tuple) && return all(_finite_metadata, value)
    return value isa AbstractString || value===nothing
end
function _evidence_json(value)
    _finite_metadata(value) ||
        throw(ArgumentError("packed witness metadata must contain finite JSON values"))
    return sprint(_light_json, value)
end
_evidence_parse(value) = YAML.load(String(value); dicttype = Dict{String,Any})
_evidence_attributes(object) =
    Dict{String,Any}(key=>read_attribute(object, key) for key in keys(attributes(object)))

function _write_packed_column(parent, name, data)
    if data isa Vector{String} && !isempty(data) && sum(ncodeunits, data)>=4096
        # Variable-length HDF5 strings place their bytes outside filtered chunks.
        # Fixed-width UTF-8 dictionaries let deflate remove repeated annotations,
        # including repeated path descriptions, without changing the string API.
        longest=data[argmax(ncodeunits.(data))]
        width=max(1, ncodeunits(longest))
        datatype=_hdf5_call(:datatype, longest)
        try
            dataset=_hdf5_call(
                :create_dataset,
                parent,
                name,
                datatype,
                (length(data),);
                chunk = (max(1, min(length(data), div(256*1024, width))),),
                deflate = 1,
            )
            # HDF5 has no variable-length UTF-8 -> fixed UTF-8 conversion path.
            # Pass a fixed-width memory buffer of exactly the declared datatype.
            buffer=zeros(UInt8, width, length(data))
            for (index, value) in enumerate(data)
                copyto!(view(buffer, :, index), 1, codeunits(value), 1, ncodeunits(value))
            end
            _hdf5_call(:write_dataset, dataset, datatype, buffer)
            return dataset
        finally
            _hdf5_call(:close, datatype)
        end
    end
    return _write_native_dataset(parent, name, data)
end

function _witness_record(sequence, iteration, witness; problem = nothing)
    attrs=Dict{String,Any}(
        "sequence"=>sequence,
        "iteration"=>iteration,
        "matrix_kind"=>String(witness.matrix_kind),
    )
    if problem!==nothing
        attrs["E0_eV"]=problem.scales.E₀_eV
        attrs["L0_m"]=problem.scales.L₀_m
    end
    groups=Dict{String,Any}("matrices_dimensionless"=>Dict{String,Any}())
    payloads=Any[]
    function add_complex(path, value, axes, units)
        groups[path]=Dict("representation"=>"split_complex")
        for (component, data) in (("real", real.(value)), ("imag", imag.(value)))
            descriptor=Dict{String,Any}(
                "path"=>path*"/"*component,
                "shape"=>collect(size(value)),
                "attributes"=>Dict{String,Any}(
                    "logical_shape"=>join(size(value), ","),
                    "storage_contract"=>"reverse-axis compensation for row-major HDF5 readers",
                    "logical_axis_order"=>axes,
                    "units"=>units,
                    "logical_dtype"=>"Float64",
                    "native_precision"=>"IEEE binary64",
                    "nonfinite_semantics"=>"NaN/Inf are preserved diagnostic invalid values, never imputed as zero",
                ),
            )
            push!(payloads, (metadata = descriptor, values = vec(_storage_order(data))))
        end
    end
    for name in sort!(collect(keys(witness.matrices)))
        (isempty(name)||occursin('/', name)) &&
            throw(ArgumentError("invalid witness matrix name"))
        add_complex(
            "matrices_dimensionless/"*name,
            witness.matrices[name],
            "a,b",
            "dimensionless; see owning scale system",
        )
    end
    add_complex("critical_eigenvector", witness.eigenvector, "state", "1")
    return (
        sequence = Int64(sequence),
        attributes = attrs,
        groups = groups,
        payloads = payloads,
    )
end


function _write_packed_witness_records!(parent, records)
    target=create_group(parent, "selected_blocks")
    attributes(target)["schema"]=_PACKED_PSD_SCHEMA
    attributes(target)["index_origin"]=0
    attributes(
        target,
    )["value_order"]="external C order; dataset_metadata_json shapes use HDF5 external axis order"
    attributes(
        target,
    )["precision"]="IEEE binary64 payload bits preserved, including NaN payload and signed zero"
    records=sort!(collect(records); by = record->record.sequence)
    sequences=Int64[record.sequence for record in records]
    length(unique(sequences))==length(sequences) ||
        throw(ArgumentError("duplicate packed PSD sequence"))
    group_metadata=String[]
    dataset_metadata=String[]
    group_lookup=Dict{String,Int64}()
    dataset_lookup=Dict{String,Int64}()
    group_index=Int64[]
    payload_record=Int64[]
    payload_metadata=Int64[]
    offsets=Int64[0]
    values=Float64[]
    function intern!(dictionary, value)
        encoded=_evidence_json(value)
        lookup=dictionary===group_metadata ? group_lookup : dataset_lookup
        return get!(lookup, encoded) do
            push!(dictionary, encoded)
            Int64(length(dictionary)-1)
        end
    end
    for (record_index, record) in enumerate(records)
        push!(group_index, intern!(group_metadata, record.groups))
        for payload in record.payloads
            prod(Int.(payload.metadata["shape"]))==length(payload.values) ||
                throw(DimensionMismatch("PSD descriptor shape differs from payload"))
            push!(payload_record, record_index-1)
            push!(payload_metadata, intern!(dataset_metadata, payload.metadata))
            append!(values, payload.values)
            push!(offsets, length(values))
        end
    end
    for (name, data) in (
        ("record_sequence", sequences),
        (
            "record_attributes_json",
            String[_evidence_json(record.attributes) for record in records],
        ),
        ("group_metadata_json", group_metadata),
        ("record_group_metadata_index", group_index),
        ("dataset_metadata_json", dataset_metadata),
        ("payload_record_index", payload_record),
        ("payload_metadata_index", payload_metadata),
        ("payload_offsets", offsets),
        ("payload_values", values),
    )
        _write_packed_column(target, name, data)
    end
    return target
end

function _read_packed_witness_records(table)
    _require_packed_witness_schema(table)
    sequence=read(table["record_sequence"])
    record_attrs=read(table["record_attributes_json"])
    group_metadata=_evidence_parse.(read(table["group_metadata_json"]))
    group_index=read(table["record_group_metadata_index"])
    metadata=_evidence_parse.(read(table["dataset_metadata_json"]))
    record_index=read(table["payload_record_index"])
    metadata_index=read(table["payload_metadata_index"])
    offsets=read(table["payload_offsets"])
    values=read(table["payload_values"])
    length(unique(sequence))==length(sequence) ||
        throw(ArgumentError("duplicate packed PSD sequence"))
    eltype(values)===Float64 || throw(ArgumentError("packed PSD values must use Float64"))
    length(record_attrs)==length(group_index)==length(sequence) ||
        throw(DimensionMismatch("packed PSD record columns differ"))
    length(record_index)==length(metadata_index)==length(offsets)-1 ||
        throw(DimensionMismatch("packed PSD payload columns differ"))
    !isempty(offsets) &&
    first(offsets)==0 &&
    last(offsets)==length(values) &&
    issorted(offsets) || throw(ArgumentError("invalid packed PSD offsets"))
    records=Any[]
    for i in eachindex(sequence)
        0<=group_index[i]<length(group_metadata) ||
            throw(ArgumentError("invalid packed PSD group index"))
        record=(
            sequence = sequence[i],
            attributes = _evidence_parse(record_attrs[i]),
            groups = group_metadata[group_index[i]+1],
            payloads = Any[],
        )
        Int(record.attributes["sequence"])==sequence[i] ||
            throw(ArgumentError("packed PSD sequence metadata differs"))
        push!(records, record)
    end
    for i in eachindex(record_index)
        0<=record_index[i]<length(records) && 0<=metadata_index[i]<length(metadata) ||
            throw(ArgumentError("invalid packed PSD payload index"))
        descriptor=metadata[metadata_index[i]+1]
        prod(Int.(descriptor["shape"]))==offsets[i+1]-offsets[i] ||
            throw(DimensionMismatch("packed PSD shape differs"))
        push!(
            records[record_index[i]+1].payloads,
            (metadata = descriptor, values = values[(offsets[i]+1):offsets[i+1]]),
        )
    end
    return records
end

function _packed_witness_components(record)
    payloads=Dict(payload.metadata["path"]=>payload for payload in record.payloads)
    length(payloads)==length(record.payloads) ||
        throw(ArgumentError("duplicate packed PSD dataset path"))
    function component(path)
        payload=payloads[path]
        return _restore_order(
            reshape(payload.values, Tuple(reverse(Int.(payload.metadata["shape"])))),
        )
    end
    names=Set(
        split(path, '/')[2] for
        path in keys(payloads) if startswith(path, "matrices_dimensionless/")
    )
    matrices=Dict{String,Matrix{ComplexF64}}(
        name=>component("matrices_dimensionless/"*name*"/real") .+
              im .* component("matrices_dimensionless/"*name*"/imag") for name in names
    )
    vector=component("critical_eigenvector/real") .+
           im .* component("critical_eigenvector/imag")
    return matrices, Vector{ComplexF64}(vector)
end
