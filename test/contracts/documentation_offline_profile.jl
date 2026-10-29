# Execute the recipe's actual pre-import guards only; no package or renderer loads.
module DocumentationOfflineProfileTests
using Test

const RECIPE = normpath(joinpath(@__DIR__, "..", "..", "docs", "make.jl"))
const COMPONENT = "runner"

function guard_program()
    expressions = filter(x -> !(x isa LineNumberNode), Meta.parseall(read(RECIPE, String)).args)
    @assert length(expressions) == 3
    profile, supported, branch = expressions
    @assert branch isa Expr && branch.head == :if
    body = branch.args[2]
    @assert body isa Expr && body.head == :block
    boundary = findfirst(x -> x isa Expr && x.head == :using, body.args)
    @assert boundary !== nothing
    prefix = Expr(:block, body.args[1:boundary-1]...)
    # Preserve actual profile predicates; never evaluate either import/render branch.
    return Expr(:block, profile, supported, Expr(:if, branch.args[1], prefix, nothing))
end

function fixture(f)
    mktempdir() do temporary
        base = realpath(temporary)
        root = joinpath(base, "immutable workspace λ")
        attempt = joinpath(base, "fresh attempt δ")
        source = joinpath(attempt, "stage", COMPONENT, "src")
        build = joinpath(attempt, "raw", COMPONENT)
        mkpath(joinpath(root, "julia"))
        mkpath(source)
        mkpath(dirname(build))
        write(joinpath(root, "julia", "Project.toml"), "[deps]\n")
        write(joinpath(root, "julia", "Manifest.toml"), "# Synthetic guard input; never loaded.\n")
        paths = Dict("QCL_DOCS_ROOT" => root, "QCL_DOCS_ATTEMPT" => attempt,
                     "QCL_DOCS_SOURCE" => source, "QCL_DOCS_BUILD" => build)
        f(paths)
    end
end

function guarded(paths; profile="offline-v1", project=joinpath(paths["QCL_DOCS_ROOT"], "julia", "Project.toml"), version=VERSION)
    previous = Base.ACTIVE_PROJECT[]
    environment = Pair{String,Union{String,Nothing}}[key => get(paths, key, nothing) for key in
        ("QCL_DOCS_ROOT", "QCL_DOCS_ATTEMPT", "QCL_DOCS_SOURCE", "QCL_DOCS_BUILD")]
    push!(environment, "QCL_DOCS_PROFILE" => profile)
    try
        Base.set_active_project(project)
        return withenv(environment...) do
            scope = Module(gensym(:DocumentationGuard))
            # A local binding exercises the unmodified recipe VERSION predicate.
            Core.eval(scope, :(const VERSION = $version))
            Core.eval(scope, guard_program())
            scope
        end
    finally
        Base.set_active_project(previous)
    end
end

function rejected(paths, message; kwargs...)
    failure = try
        guarded(paths; kwargs...)
        nothing
    catch error
        error
    end
    @test failure isa ErrorException
    if failure isa ErrorException
        @test occursin(message, sprint(showerror, failure))
    end
end

@testset "ordinary offline documentation guards ($COMPONENT)" begin
    before_modules = Set(keys(Base.loaded_modules))
    before_project = Base.ACTIVE_PROJECT[]
    before_environment = Dict(name => get(ENV, name, nothing) for name in
        ("QCL_DOCS_PROFILE", "QCL_DOCS_ROOT", "QCL_DOCS_ATTEMPT", "QCL_DOCS_SOURCE", "QCL_DOCS_BUILD"))
    for profile in ("offline-v1", "pilot-v1")
        @testset "$profile healthy" begin
            fixture() do paths
                scope = guarded(paths; profile)
                @test Core.eval(scope, :_qcl_docs_source) == paths["QCL_DOCS_SOURCE"]
                @test Core.eval(scope, :_qcl_docs_build) == paths["QCL_DOCS_BUILD"]
                @test !ispath(paths["QCL_DOCS_BUILD"])
                @test !Base.invokelatest(isdefined, scope, :makedocs)
                @test !Base.invokelatest(isdefined, scope, :QCLNEGFRunner)
            end
        end
    end
    @testset "local route and invalid profile" begin
        scope = guarded(Dict{String,String}(); profile="", project=nothing)
        @test !Base.invokelatest(isdefined, scope, :_qcl_docs_root)
        rejected(Dict{String,String}(), "Unsupported QCL_DOCS_PROFILE"; profile="offline-v2", project=nothing)
    end
    @testset "required and canonical paths" begin
        for name in ("QCL_DOCS_ROOT", "QCL_DOCS_ATTEMPT", "QCL_DOCS_SOURCE", "QCL_DOCS_BUILD")
            fixture() do paths
                paths[name] = ""
                rejected(paths, "required"; project=nothing)
            end
            for invalid in ("relative", "/trailing/", "/double//slash", "/dot/./part", "/parent/../part")
                fixture() do paths
                    paths[name] = invalid
                    rejected(paths, invalid == "relative" ? "absolute" : "canonical"; project=nothing)
                end
            end
            fixture() do paths
                original = paths[name]
                link = joinpath(dirname(original), "linked")
                symlink(original, link)
                paths[name] = link
                rejected(paths, "symlink"; project=nothing)
            end
        end
    end
    @testset "existence, nonoverlap, layout and fresh output" begin
        for name in ("QCL_DOCS_ROOT", "QCL_DOCS_ATTEMPT", "QCL_DOCS_SOURCE")
            fixture() do paths
                paths[name] *= " missing"
                rejected(paths, "directory is missing"; project=nothing)
            end
        end
        fixture() do paths
            paths["QCL_DOCS_BUILD"] = joinpath(paths["QCL_DOCS_ATTEMPT"], "missing", COMPONENT)
            rejected(paths, "directory is missing")
        end
        fixture() do paths
            paths["QCL_DOCS_ROOT"] = paths["QCL_DOCS_ATTEMPT"]
            rejected(paths, "ROOT and ATTEMPT must not overlap"; project=nothing)
        end
        fixture() do paths
            paths["QCL_DOCS_BUILD"] = joinpath(paths["QCL_DOCS_SOURCE"], "output")
            rejected(paths, "SOURCE and BUILD must not overlap")
        end
        for kind in (:directory, :file, :dangling_symlink)
            fixture() do paths
                build = paths["QCL_DOCS_BUILD"]
                kind == :directory ? mkdir(build) : kind == :file ? write(build, "sentinel") : symlink("missing", build)
                rejected(paths, kind == :dangling_symlink ? "symlink" : "already exist")
                @test ispath(build) || islink(build)
                kind == :file && @test read(build, String) == "sentinel"
            end
        end
        fixture() do paths
            paths["QCL_DOCS_SOURCE"] = mkpath(joinpath(paths["QCL_DOCS_ATTEMPT"], "other", "src"))
            rejected(paths, "SOURCE does not match")
        end
        fixture() do paths
            paths["QCL_DOCS_BUILD"] *= "-other"
            rejected(paths, "BUILD does not match")
        end
    end
    @testset "project, ancestry and version" begin
        for leaf in ("Project.toml", "Manifest.toml")
            fixture() do paths
                rm(joinpath(paths["QCL_DOCS_ROOT"], "julia", leaf))
                rejected(paths, "project input")
            end
            fixture() do paths
                path = joinpath(paths["QCL_DOCS_ROOT"], "julia", leaf)
                mv(path, path * ".target")
                symlink(path * ".target", path)
                rejected(paths, "symlink")
            end
        end
        fixture() do paths
            julia = joinpath(paths["QCL_DOCS_ROOT"], "julia")
            mv(julia, julia * "-target")
            symlink(julia * "-target", julia)
            rejected(paths, "symlink")
        end
        fixture() do paths
            rejected(paths, "active project"; project=joinpath(paths["QCL_DOCS_ROOT"], "other.toml"))
        end
        fixture() do paths
            rejected(paths, "Julia 1.13.0"; version=v"1.12.0")
        end
    end
    @test Set(keys(Base.loaded_modules)) == before_modules
    @test Base.ACTIVE_PROJECT[] == before_project
    @test all(get(ENV, name, nothing) == value for (name, value) in before_environment)
end
end
