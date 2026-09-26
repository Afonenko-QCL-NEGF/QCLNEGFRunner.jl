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
