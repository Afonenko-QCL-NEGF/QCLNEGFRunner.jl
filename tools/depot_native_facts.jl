# Included only by explicit native depot capture; never executes a scientific workflow.
using SHA, TOML
using Base.BinaryPlatforms: HostPlatform, triplet

function depot_json(value)
    if value isa AbstractDict
        return "{" * join((depot_json(string(k)) * ":" * depot_json(value[k])
                           for k in sort!(collect(keys(value)); by=string)), ",") * "}"
    elseif value isa AbstractVector
        return "[" * join(depot_json.(value), ",") * "]"
    elseif value isa AbstractString
        io = IOBuffer(); print(io, '"')
        for c in value
            if c == '"'; print(io, "\\\"")
            elseif c == '\\'; print(io, "\\\\")
            elseif Int(c) < 0x20; print(io, "\\u", string(Int(c); base=16, pad=4))
            else; print(io, c)
            end
        end
        print(io, '"'); return String(take!(io))
    elseif value === nothing
        return "null"
    elseif value isa Bool
        return value ? "true" : "false"
    elseif value isa Real && isfinite(value)
        return string(value)
    end
    error("Unsupported native fact value")
end

function depot_check_defaults(project)
    LOAD_PATH == ["@", "@stdlib"] || error("V2 requires isolated LOAD_PATH")
    length(DEPOT_PATH) == 1 && only(DEPOT_PATH) == get(ENV, "JULIA_DEPOT_PATH", "") ||
        error("V2 requires one explicit fresh depot")
    get(ENV, "JULIA_CPU_TARGET", "") == "generic" || error("V2 requires generic CPU target")
    isempty(ARGS) && error("V2 native facts need explicit output")
    roots = [dirname(project), normpath(joinpath(dirname(project), "../components/QCLNEGF.jl")),
             normpath(joinpath(dirname(project), "../components/QCLNEGFRunner.jl"))]
    for root in roots
        ispath(joinpath(root, ".pkg")) && error("Local selectors require qualification")
        for name in ("LocalPreferences.toml", "JuliaLocalPreferences.toml")
            ispath(joinpath(root, name)) && error("Custom preferences require qualification")
        end
        for name in ("Project.toml", "JuliaProject.toml")
            file = joinpath(root, name)
            isfile(file) && haskey(TOML.parsefile(file), "preferences") &&
                error("Custom exported local preferences require qualification")
        end
    end
    ispath(joinpath(only(DEPOT_PATH), "artifacts", "Overrides.toml")) &&
        error("Artifact overrides require qualification")
    return Set(realpath.(roots))
end

function depot_capture_facts(path, allowed_roots)
    dependencies = Pkg.dependencies()
    preferences = Dict{String,Any}()
    selectors = Dict{String,Any}[]
    artifacts = Dict{String,Any}[]
    roots = Tuple{String,String,Union{Nothing,String}}[("environment", dirname(Base.active_project()), nothing)]
    for (uuid, info) in sort!(collect(dependencies); by=x -> string(first(x)))
        # Fresh Pkg downloads verify tree hashes; also verify captured package trees.
        if info.tree_hash !== nothing
            bytes2hex(Pkg.GitTools.tree_hash(info.source)) == info.tree_hash ||
                error("Captured dependency source tree differs from Manifest")
        elseif info.is_tracking_path
            realpath(info.source) in allowed_roots || error("Unqualified local dependency")
        else
            Pkg.Types.is_stdlib(uuid) || error("External dependency has no locked tree hash")
        end
        preferences[string(uuid)] = Base.get_preferences(uuid)
        push!(roots, (string(uuid), info.source, info.tree_hash))
    end
    platform = HostPlatform()
    for (uuid, root, tree) in roots
        alias = findfirst(name -> isfile(joinpath(root, name)), ("JuliaArtifacts.toml", "Artifacts.toml"))
        alias === nothing && continue
        name = ("JuliaArtifacts.toml", "Artifacts.toml")[alias]
        selector = joinpath(root, ".pkg", "select_artifacts.jl")
        augmentation = joinpath(root, ".pkg", "platform_augmentation.jl")
        push!(selectors, Dict("uuid"=>uuid, "tree"=>tree, "artifacts_file"=>name,
            "selector_sha256"=>isfile(selector) ? bytes2hex(sha256(read(selector))) : nothing,
            "augmentation_sha256"=>isfile(augmentation) ? bytes2hex(sha256(read(augmentation))) : nothing))
        for (_, selected) in Pkg.Operations.collect_artifacts(root; platform, include_lazy=true)
            for (artifact, data) in sort!(collect(selected); by=first)
                hash = Base.SHA1(data["git-tree-sha1"])
                Pkg.Artifacts.verify_artifact(hash; honor_overrides=true) ||
                    error("Captured artifact tree differs")
                push!(artifacts, Dict("uuid"=>uuid, "tree"=>tree, "artifact"=>artifact,
                    "artifact_tree"=>string(hash), "platform"=>triplet(platform),
                    "selection"=>Dict(k=>v for (k,v) in data if !(k in ("download", "git-tree-sha1", "lazy")))))
            end
        end
    end
    sort!(selectors; by=x -> x["uuid"])
    sort!(artifacts; by=x -> (x["uuid"], x["artifact"]))
    depot_check_defaults(Base.active_project())
    for info in values(dependencies)
        info.tree_hash === nothing && continue
        bytes2hex(Pkg.GitTools.tree_hash(info.source)) == info.tree_hash ||
            error("Dependency source changed during selection")
    end
    raw = depot_json(Dict("observed_platform"=>triplet(platform), "preferences"=>Dict(
        "packages"=>preferences, "environment"=>Dict("load_path"=>copy(LOAD_PATH),
        "depot_path"=>copy(DEPOT_PATH), "active_project"=>Base.active_project(),
        "manifest"=>Pkg.Types.Context().env.manifest_file,
        "cpu_target"=>get(ENV, "JULIA_CPU_TARGET", ""))),
                          "selectors"=>selectors, "artifacts"=>artifacts)) * "\n"
    ncodeunits(raw) <= 65536 || error("Native facts exceed bounded capture")
    fs = Base.Filesystem
    file = fs.open(path, fs.JL_O_WRONLY | fs.JL_O_CREAT | fs.JL_O_EXCL | fs.JL_O_NOFOLLOW, 0o600)
    try
        write(file, raw)
        ccall(:fsync, Cint, (Base.RawFD,), fd(file)) == 0 || error("Native facts fsync failed")
    finally
        close(file)
    end
    parent = fs.open(dirname(path), fs.JL_O_RDONLY | fs.JL_O_DIRECTORY | fs.JL_O_NOFOLLOW)
    try
        ccall(:fsync, Cint, (Base.RawFD,), fd(parent)) == 0 || error("Native facts parent fsync failed")
    finally
        close(parent)
    end
    return nothing
end
