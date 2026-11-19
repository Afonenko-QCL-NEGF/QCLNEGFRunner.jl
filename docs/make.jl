using QCLNEGFRunner, Documenter
DocMeta.setdocmeta!(QCLNEGFRunner, :DocTestSetup, :(using QCLNEGFRunner, Unitful, LinearAlgebra); recursive = true)
makedocs(
    modules = [QCLNEGFRunner],
    remotes = nothing,
    sitename = "QCLNEGFRunner",
    format = Documenter.HTML(prettyurls = false, edit_link = nothing, lang = "ru",
        footer = "Документация создана с помощью [Documenter.jl](https://github.com/JuliaDocs/Documenter.jl) и [Julia](https://julialang.org/).",
        repolink = "https://github.com/Afonenko-QCL-NEGF/QCLNEGFRunner.jl"),
    pages = [
        "Главная" => "index.md",
        "Руководство" => ["user/comparison.md", "user/configuration.md", "user/plotting.md", "user/resources.md", "user/results.md"],
        "API" => ["api/public.md", "api/extensions.md"],
        "Разработка" => ["developer/architecture.md"],
    ],
    doctest = true,
    checkdocs = :exports,
    warnonly = false,
)
include("localize_html.jl")
localize_documenter!(joinpath(@__DIR__, "build"))
