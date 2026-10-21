# Dependency capture only. No scientific workflow is started.
using Pkg

VERSION == v"1.13.0" || error("Prepared depots require the pinned Julia 1.13.0 runtime")
ctx = Pkg.Types.Context()
isfile(ctx.env.project_file) || error("Prepared depots require an existing Project file: $(ctx.env.project_file)")
isfile(ctx.env.manifest_file) || error("Prepared depots require an existing Manifest file: $(ctx.env.manifest_file)")
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
