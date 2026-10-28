# Dependency capture only. No scientific workflow is started.
using Pkg

VERSION == v"1.13.0" || error("Prepared depots require the pinned Julia 1.13.0 runtime")
native_facts = !isempty(ARGS)
native_facts && (length(ARGS) != 2 || ARGS[1] != "--facts" || !isabspath(ARGS[2])) &&
    error("Use --facts ABSOLUTE_NEW_FILE for explicit V2 capture")
native_facts && include("depot_native_facts.jl")
ctx = Pkg.Types.Context()
if native_facts
    basename(ctx.env.project_file) == "Project.toml" || error("Unqualified Project alias")
    basename(ctx.env.manifest_file) == "Manifest.toml" || error("Unqualified Manifest alias")
end
isfile(ctx.env.project_file) || error("Prepared depots require an existing Project file: $(ctx.env.project_file)")
isfile(ctx.env.manifest_file) || error("Prepared depots require an existing Manifest file: $(ctx.env.manifest_file)")
manifest_before = read(ctx.env.manifest_file)
allowed_roots = native_facts ? depot_check_defaults(ctx.env.project_file) : Set{String}()
Pkg.instantiate(ctx; manifest=true, allow_build=false, allow_autoprecomp=false, julia_version_strict=true)

# Instantiate omits lazy artifacts. Capture the full selection for this host now,
# while downloads are allowed, so a later sandbox build has no deferred fetches.
# These internal APIs are deliberately bound to the Julia 1.13.0 runtime above.
Pkg.Operations.download_artifacts(Pkg.Types.Context(); include_lazy=true)
roots = Set([dirname(Base.active_project())])
union!(roots, (info.source for info in values(Pkg.dependencies())))
verified = Set{Base.SHA1}()
for source in roots
    for (_, artifacts) in Pkg.Operations.collect_artifacts(source; include_lazy=true)
        for artifact in values(artifacts)
            hash = Base.SHA1(artifact["git-tree-sha1"])
            hash in verified && continue
            Pkg.Artifacts.verify_artifact(hash; honor_overrides=true) ||
                error("Prepared artifact failed tree-hash verification: $hash")
            push!(verified, hash)
        end
    end
end
isempty(Pkg.Registry.reachable_registries()) && error("Prepared depot omitted its frozen registry")

read(ctx.env.manifest_file) == manifest_before || error("Dependency capture changed the frozen Manifest")
if native_facts
    depot_check_defaults(ctx.env.project_file)
    depot_capture_facts(ARGS[2], allowed_roots)
end
