# Regenerate test/known_failures.toml: the corpus entries that identify() currently gets wrong.
# Git sources are only checked (and recorded by url and hash) if REPOLOGY_TEST_NETWORK is set.
using Repology, TOML
corpus = TOML.parsefile(joinpath(@__DIR__, "..", "test", "corpus.toml"))["entry"]
failures = []
network = !isempty(get(ENV, "REPOLOGY_TEST_NETWORK", ""))
for e in corpus
    haskey(e, "hash") && !network && continue
    id = Repology.identify(e["url"]; commit=get(e, "hash", nothing), use_overrides=false)
    id.version == e["version"] && id.project == e["project"] && continue
    push!(failures, Dict("url" => e["url"], (haskey(e, "hash") ? ("hash" => e["hash"],) : ())..., "expected" => "$(e["project"]) $(e["version"])",
        "got" => "$(something(id.project, "nothing")) $(something(id.version, "nothing"))"))
end
unique!(f -> (f["url"], get(f, "hash", "")), failures)
open(joinpath(@__DIR__, "..", "test", "known_failures.toml"), "w") do io
    println(io, "# Corpus entries that Repology.identify currently gets wrong. Regenerate with scripts/known_failures.jl.")
    TOML.print(io, Dict("failure" => failures); sorted=true)
end
println(length(failures), " known failures")
