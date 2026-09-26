#!/usr/bin/env julia
# Package-manager generated integration environment; never edit component projects.
using Pkg
using TOML
length(ARGS) in (3, 4) || error("usage: prepare_workspace.jl CORE RUNNER ENVIRONMENT [--runtime-only]")
core, runner, environment = abspath.(ARGS[1:3])
runtime_only = length(ARGS) == 4
runtime_only && ARGS[4] != "--runtime-only" && error("unknown option")
for path in (core, runner)
    isfile(joinpath(path, "Project.toml")) || error("missing package Project.toml: $path")
end
for package in (core, runner)
    relative = relpath(environment, package)
    (relative == "." || !(relative == ".." || startswith(relative, "../"))) &&
        error("integration environment must be outside component repositories")
end
mkpath(environment)
Pkg.activate(environment)
cd(environment) do
    Pkg.develop([PackageSpec(path=relpath(core, environment)), PackageSpec(path=relpath(runner, environment))])
end
if !runtime_only
    dependencies = Dict{String,String}()
    for package in (core, runner)
        merge!(dependencies, TOML.parsefile(joinpath(package, "test", "Project.toml"))["deps"])
    end
    for name in ("QCLNEGF", "QCLNEGFRunner")
        pop!(dependencies, name, nothing)
    end
    specs = [PackageSpec(name=name, uuid=uuid) for (name, uuid) in sort!(collect(dependencies))]
    push!(specs, PackageSpec(name="Documenter", version="1.17"))
    Pkg.add(specs)
end
Pkg.instantiate()
