"""
Resolve an installed package resource when it is used.

Julia package images can move from the build tree to another installation
prefix. Source-location macros embedded in those images still describe the
build tree, so resource and provenance paths must use the currently loaded
package location instead. The caller's working directory is not a fallback.
"""
function _package_path(parts::AbstractString...)
    root = pkgdir(@__MODULE__)
    root === nothing && throw(ArgumentError("cannot locate the loaded QCLNEGFRunner package"))
    return joinpath(root, parts...)
end

"""Direct runtime provenance for each standalone scientific artifact."""
function _runtime_toolchain_provenance()
    digest(path) = isfile(path) ? bytes2hex(SHA.sha256(read(path))) : nothing
    root = _package_path()
    active_project = something(Base.active_project(), joinpath(root, "Project.toml"))
    binary = joinpath(Sys.BINDIR, "julia")
    preference_files = Dict{String,Any}[]
    projects = unique(vcat([joinpath(root, "Project.toml")], Base.load_path()))
    for (index, project) in enumerate(projects)
        isfile(project) || continue
        preference = joinpath(dirname(project), "LocalPreferences.toml")
        isfile(preference) || continue
        push!(
            preference_files,
            Dict{String,Any}("load_path_index" => index, "sha256" => digest(preference)),
        )
    end
    # The executable and each loaded preference file are hashed directly.
    # Their paths are deliberately absent: relocating an identical installation
    # must not change its scientific identity.
    return Dict{String,Any}(
        "schema" => "qcl-negf-toolchain-provenance/v1",
        "julia_version" => string(VERSION),
        "runtime_binary_sha256" => digest(binary),
        "manifest_sha256" => digest(joinpath(dirname(active_project), "Manifest.toml")),
        "project_sha256" => digest(active_project),
        "core_project_sha256" => digest(joinpath(pkgdir(QCLNEGF), "Project.toml")),
        "runner_project_sha256" => digest(joinpath(root, "Project.toml")),
        "preferences" => preference_files,
        "architecture" => string(Sys.ARCH),
        "kernel" => string(Sys.KERNEL),
        "julia_threads" => Threads.nthreads(:default),
        "gc_threads" => Threads.ngcthreads(),
        "blas_threads" => BLAS.get_num_threads(),
        "blas_backend" => string(BLAS.get_config()),
        "fftw_provider" => string(FFTW.get_provider()),
        "fftw_threads" => FFTW.get_num_threads(),
    )
end

# Capture actual source files once per invocation. These hashes are not Git attestation.
function _capture_solver_sources_at(core_root::AbstractString, runner_root::AbstractString)
    records=Dict{String,Any}[]
    core_records=nothing
    for (name,package_root) in (("QCLNEGF",core_root),("QCLNEGFRunner",runner_root))
        root,paths=_runtime_source_files(package_root)
        isfile(joinpath(root,"Project.toml")) && isdir(joinpath(root,"src")) && length(paths)>1 ||
            throw(ArgumentError("exact_execution_runtime_unavailable:source_files"))
        own=QCLApplicationRuntime.fingerprint_sources(paths;root)
        name=="QCLNEGF" && (core_records=deepcopy(own))
        for item in own
            record=deepcopy(item);record["path"]=name*"/"*record["path"];push!(records,record)
        end
    end
    sort!(records;by=r->r["path"])
    return Dict{String,Any}("solver_source_files"=>records,
        "core_source_sha256"=>bytes2hex(sha256(QCLApplicationRuntime.canonical_bytes(core_records))))
end

_capture_solver_sources() = _capture_solver_sources_at(pkgdir(QCLNEGF), pkgdir(QCLNEGFRunner))

function _p05_library_file(path::AbstractString)
    try
        resolved=realpath(path)
        isfile(resolved) || throw(ArgumentError("not a regular library"))
        return Dict{String,Any}("path"=>resolved,"bytes"=>filesize(resolved),
            "sha256"=>open(io->bytes2hex(sha256(io)),resolved))
    catch error
        error isa InterruptException && rethrow()
        throw(ArgumentError("exact_execution_runtime_unavailable:library_file"))
    end
end

function _p05_fact(value,field)
    value === nothing && throw(ArgumentError("exact_execution_runtime_unavailable:$field"))
    result=string(value)
    isempty(strip(result)) || lowercase(strip(result)) in ("unknown","not_measured","nothing") ?
        throw(ArgumentError("exact_execution_runtime_unavailable:$field")) : result
end

function _p05_runtime_library_facts()
    config=BLAS.get_config()
    isempty(config.loaded_libs) && throw(ArgumentError("exact_execution_runtime_unavailable:blas"))
    libraries=Dict{String,Any}[]
    for lib in config.loaded_libs
        data=_p05_library_file(Libdl.dlpath(lib.handle))
        data["configured_libname"]=_p05_fact(lib.libname,"blas_libname")
        for field in (:suffix,:interface,:complex_retstyle,:f2c,:cblas)
            value=getproperty(lib,field)
            # Empty symbol suffix is a valid ABI choice.
            data[string(field)]=field===:suffix ? string(value) : _p05_fact(value,"blas_$(field)")
        end
        data["interface"] in ("ilp64","lp64") || throw(ArgumentError("exact_execution_runtime_unavailable:blas_interface"))
        forwards=copy(lib.active_forwards)
        isempty(forwards) && throw(ArgumentError("exact_execution_runtime_unavailable:blas_forwards"))
        data["active_forwards_sha256"]=bytes2hex(sha256(forwards))
        data["active_forwards_bytes"]=length(forwards)
        push!(libraries,data)
    end
    symbols=String.(config.exported_symbols)
    isempty(symbols) && throw(ArgumentError("exact_execution_runtime_unavailable:blas_symbols"))
    blas=Dict{String,Any}("threads"=>BLAS.get_num_threads(),
        "build_flags"=>sort!(string.(config.build_flags)),
        "exported_symbols_count"=>length(symbols),
        "exported_symbols_sha256"=>bytes2hex(sha256(join(symbols,"\n"))),"libraries"=>libraries)
    blas["threads"]>0 || throw(ArgumentError("exact_execution_runtime_unavailable:blas_threads"))
    provider=_p05_fact(getproperty(FFTW,:fftw_provider),"fftw_provider")
    provider=="fftw" || throw(ArgumentError("exact_execution_runtime_unavailable:fftw_provider"))
    fftthreads=FFTW.get_num_threads()
    fftthreads>0 || throw(ArgumentError("exact_execution_runtime_unavailable:fftw_threads"))
    fftroot=pkgdir(FFTW); fftpaths=String[joinpath(fftroot,"Project.toml")]
    for (dir,_,names) in walkdir(joinpath(fftroot,"src"))
        append!(fftpaths,joinpath.(dir,filter(n->endswith(n,".jl"),names)))
    end
    isfile(first(fftpaths)) && length(fftpaths)>1 || throw(ArgumentError("exact_execution_runtime_unavailable:fftw_source"))
    fftsource=QCLApplicationRuntime.fingerprint_sources(sort!(fftpaths);root=fftroot)
    function fftlib(binding,symbol)
        name=getproperty(FFTW,binding)
        name isa AbstractString && !isempty(name) || throw(ArgumentError("exact_execution_runtime_unavailable:fftw_binding"))
        handle=Libdl.dlopen(name)
        try
            data=_p05_library_file(Libdl.dlpath(handle))
            data["fresh_version_string"]=_p05_fact(unsafe_string(Ptr{UInt8}(Libdl.dlsym(handle,symbol))),"fftw_version")
            startswith(data["fresh_version_string"],"fftw-") || throw(ArgumentError("exact_execution_runtime_unavailable:fftw_version"))
            return data
        finally
            Libdl.dlclose(handle)
        end
    end
    fftw=Dict{String,Any}("provider_loaded"=>provider,"package_version"=>_p05_fact(Base.pkgversion(FFTW),"fftw_package"),
        "threads"=>fftthreads,"source_files"=>fftsource,
        "double"=>fftlib(:libfftw3_no_init,:fftw_version),
        "single"=>fftlib(:libfftw3f_no_init,:fftwf_version))
    return (blas=blas,fftw=fftw)
end

function _capture_exact_execution(production::ProductionOptions,sources::AbstractDict)
    production.worker_count>0 && production.worker_count<=Threads.nthreads(:default) ||
        throw(ArgumentError("exact_execution_runtime_unavailable:worker_count"))
    core=get(sources,"core_source_sha256",nothing)
    core isa String && occursin(r"^[0-9a-f]{64}\z",core) &&
        get(sources,"solver_source_files",nothing) isa AbstractVector && !isempty(sources["solver_source_files"]) ||
        throw(ArgumentError("exact_execution_runtime_unavailable:source_files"))
    records=sources["solver_source_files"]
    all(r->r isa AbstractDict && get(r,"path",nothing) isa String &&
        get(r,"bytes",nothing) isa Integer && !(r["bytes"] isa Bool) && r["bytes"]>=0 &&
        get(r,"sha256",nothing) isa String && occursin(r"^[0-9a-f]{64}\z",r["sha256"]),records) ||
        throw(ArgumentError("exact_execution_runtime_unavailable:source_files"))
    paths=[r["path"] for r in records]
    issorted(paths) && allunique(paths) || throw(ArgumentError("exact_execution_runtime_unavailable:source_files"))
    core_records=[Dict{String,Any}("path"=>replace(r["path"],r"^QCLNEGF/"=>""),
        "bytes"=>r["bytes"],"sha256"=>r["sha256"]) for r in records if startswith(r["path"],"QCLNEGF/")]
    !isempty(core_records) && any(r->r["path"]=="Project.toml",core_records) &&
        any(r->startswith(r["path"],"src/"),core_records) &&
        bytes2hex(sha256(QCLApplicationRuntime.canonical_bytes(core_records)))==core ||
        throw(ArgumentError("exact_execution_runtime_unavailable:source_files"))
    QCLNEGF.validate_options(production)
    facts=try
        _p05_runtime_library_facts()
    catch error
        error isa InterruptException && rethrow()
        error isa ArgumentError && rethrow()
        throw(ArgumentError("exact_execution_runtime_unavailable:library_metadata"))
    end
    # Paths and configured library names are locators, not content identity.
    blas_identity=deepcopy(facts.blas)
    for lib in blas_identity["libraries"];delete!(lib,"path");delete!(lib,"configured_libname");end
    fftw_identity=deepcopy(facts.fftw)
    for key in ("double","single");delete!(fftw_identity[key],"path");end
    digest(value)=bytes2hex(sha256(QCLApplicationRuntime.canonical_bytes(value)))
    execution=QCLNEGF.ExactExecutionIdentity(;core_code=core,julia=string(VERSION),
        blas=digest(blas_identity),fftw=digest(fftw_identity),scalar_type="Float64/ComplexF64",
        index_type=string(Int),reduction="static_chunks_v1",worker_count=production.worker_count,
        blas_threads=facts.blas["threads"],energy_chunk=production.energy_chunk,
        hilbert_columns=production.hilbert_columns,residual_chunk=production.residual_chunk,
        parallel_backend=production.parallel_backend)
    return (execution=execution,provenance=Dict{String,Any}("blas"=>facts.blas,"fftw"=>facts.fftw,
        "solver_source_files"=>deepcopy(sources["solver_source_files"])))
end

function _require_source_graph(source_graph::Union{Nothing,AbstractDict})
    source_graph === nothing && throw(ArgumentError("source_graph_unavailable"))
    graph=deepcopy(source_graph)
    try
        _p04_validate_provenance(graph)
    catch error
        error isa InterruptException && rethrow()
        throw(ArgumentError("invalid_source_graph"))
    end
    return graph
end
function _load_source_graph_file(path::AbstractString)
    islink(path) && throw(ArgumentError("invalid_source_graph"))
    bytes=open(io->read(io,256*1024+1),path)
    length(bytes)<=256*1024 || throw(ArgumentError("source_graph_exceeds_byte_limit"))
    text=String(bytes)
    isvalid(text) || throw(ArgumentError("invalid_source_graph"))
    graph=try
        _p04_parse(text)
    catch error
        error isa InterruptException && rethrow()
        throw(ArgumentError("invalid_source_graph"))
    end
    graph isa AbstractDict || throw(ArgumentError("invalid_source_graph"))
    return _require_source_graph(graph)
end
