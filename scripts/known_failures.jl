# Regenerate test/known_failures.toml: the corpus entries that identify() currently gets wrong (offline only).
using Repology, TOML
corpus = TOML.parsefile(joinpath(@__DIR__, "..", "test", "corpus.toml"))["entry"]
failures = []
for e in corpus
    haskey(e, "hash") && continue
    id = Repology.identify(e["url"]; use_overrides=false)
    id.version == e["version"] && (e["kind"] != "manual" || id.project == e["project"]) && continue
    push!(failures, Dict("url" => e["url"], "expected" => "$(e["project"]) $(e["version"])",
        "got" => "$(something(id.project, "nothing")) $(something(id.version, "nothing"))"))
end
unique!(f -> f["url"], failures)
open(joinpath(@__DIR__, "..", "test", "known_failures.toml"), "w") do io
    println(io, "# Corpus entries that Repology.identify currently gets wrong. Regenerate with scripts/known_failures.jl.")
    TOML.print(io, Dict("failure" => failures); sorted=true)
end
println(length(failures), " known failures")
