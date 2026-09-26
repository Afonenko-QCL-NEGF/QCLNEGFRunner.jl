using QCLNEGFRunner, Documenter
DocMeta.setdocmeta!(QCLNEGFRunner, :DocTestSetup, :(using QCLNEGFRunner, Unitful, LinearAlgebra); recursive = true)
makedocs(
    modules = [QCLNEGFRunner],
    remotes = nothing,
    sitename = "QCLNEGFRunner",
    format = Documenter.HTML(prettyurls = false, edit_link = nothing,
        repolink = "https://github.com/AfonenkoA/QCLNEGFRunner.jl"),
    pages = [
        "Home" => "index.md",
        "Using the package" => ["user/comparison.md", "user/configuration.md", "user/plotting.md", "user/resources.md", "user/results.md"],
        "API" => ["api/public.md"],
        "Development" => ["developer/architecture.md"],
    ],
    doctest = true,
    checkdocs = :exports,
    warnonly = false,
)
