using Documenter
using Repology

makedocs(;
    modules=[Repology],
    sitename="Repology.jl",
    checkdocs=:all,
    format=Documenter.HTML(; canonical="https://mbauman.github.io/Repology.jl/stable/"),
    pages=[
        "Home" => "index.md",
        "Guide" => "guide.md",
        "API reference" => "api.md",
    ],
)

deploydocs(; repo="github.com/JuliaPackaging/Repology.jl.git", devbranch="main")
