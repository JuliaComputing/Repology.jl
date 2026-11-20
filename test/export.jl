module ExportTests
using Test, TOML, DataFrames
include(joinpath(@__DIR__, "..", "scripts", "update_repology_info.jl"))

function claimant(project, family; repo=family, srcname=project, multiple_urls=false,
    url="https://example.org/widget-1.2.tar.gz", version="1.2", link_type=Int8(1))
    return (; effname=project, family, repo, srcname, binname=srcname, visiblename=srcname,
        multiple_urls, url, origversion=version, link_type)
end

@testset "source export" begin
    empty = DataFrame([claimant("widget", "one")])[1:0, :]
    result = gather_links(empty)
    @test isempty(result.downloads) && isempty(result.repositories) && isempty(result.seen)
    @test result.ambiguous == 0

    df = DataFrame([claimant("wrapper", "one"; repo="one-$i") for i in 1:10])
    append!(df, DataFrame([claimant("widget", "two"), claimant("widget", "three")]))
    result = gather_links(df)
    @test all(p -> first(p) == "widget", values(result.downloads))
    @test all(==(["three", "two"]), values(result.families))

    tie = DataFrame([claimant("python:widget", "one"; srcname="python-widget"),
        claimant("widget", "two"; srcname="libs/widget")])
    @test first(resolve_claimants(tie, 1:2)) == "widget"
    tie.srcname[2] = "another-name"
    @test isnothing(first(resolve_claimants(tie, 1:2)))
    tie.srcname[1] = "widget"
    tie.srcname[2] = "widget"
    @test isnothing(first(resolve_claimants(tie, 1:2)))
    @test !basename_agrees("https://example.org/widget.git", missing, "")
    @test basename_agrees("https://example.org/widget.git", "widget", "")

    df = DataFrame([claimant("wrapper", "one"),
        claimant("widget", "two"; multiple_urls=true), claimant("widget", "three"; multiple_urls=true)])
    @test first(resolve_claimants(df, 1:3)) == "widget"
    @test first(resolve_claimants(df, 1:3; singleton_support=true)) == "wrapper"
    winner, support = resolve_claimants(df, 2:3; singleton_support=true)
    @test isnothing(winner) && haskey(support, "widget")

    df = DataFrame([claimant("wrapper", "one"; url="http://example.org/widget-1.2.tar.gz"),
        claimant("widget", "two"), claimant("widget", "three"; url="https://example.org/widget-1.2.tar.xz")])
    result = gather_links(df)
    @test length(result.downloads) == 4
    @test all(==("widget" => "1.2"), values(result.downloads))
    @test result.downloads[Repology.normalize_url(df.url[1])] == result.downloads[df.url[1]]

    df = DataFrame([claimant("one", "one"), claimant("two", "two")])
    io = IOBuffer()
    result = gather_links(df; diagnostics=io)
    @test isempty(result.downloads) && result.ambiguous == 1
    entries = TOML.parse(String(take!(io)))["ambiguous"]
    @test length(only(entries)["claimants"]) == 2
    @test Set(c["project"] for c in only(entries)["claimants"]) == Set(["one", "two"])
    @test all(c -> haskey(c, "family") && haskey(c, "srcname") && haskey(c, "multiple_urls"), only(entries)["claimants"])

    old = Dict("http://example.org/widget-1.2.tar.xz" => "stale", "https://old.org/absent.tar.gz" => "keep")
    @test retain_unclaimed(old, Dict{String,String}(), result.seen) == Dict("https://old.org/absent.tar.gz" => "keep")
    @test retain_unclaimed(old, Dict("example.org/widget-1.2" => "new"), result.seen)["example.org/widget-1.2"] == "new"
    @test retain_unclaimed(old, Dict{String,String}(), Set{String}()) == old

    df = DataFrame([claimant("widget", "one"), claimant("widget", "two"; version="1.2.0")])
    @test all(==("widget" => "1.2"), values(gather_links(df).downloads))
    df = DataFrame([claimant("widget", "one"; version="")])
    @test all(==("widget" => ""), values(gather_links(df).downloads))
    df = DataFrame([claimant("widget", "one"; version="git")])
    @test all(==("widget" => "git"), values(gather_links(df).downloads))
    df.link_type .= 2
    @test !isempty(gather_links(df).repositories)

    df = DataFrame([claimant("wrapper", "one"; link_type=Int8(2)),
        claimant("widget", "two"; url="http://example.org/widget-1.2.tar.gz"), claimant("widget", "three")])
    result = gather_links(df)
    @test all(==("widget"), values(result.repositories))
    @test all(==("widget" => "1.2"), values(result.downloads))
    df = DataFrame([claimant("widget", "one"; version="7.0"), claimant("widget", "two"; version="8.0")])
    @test all(==("widget" => ""), values(gather_links(df).downloads))

    dump = """
    COPY repology.links (id, url) FROM stdin;
    1\thttps://example.org/widget-1.2.tar.gz
    2\thttps://example.org/widget.git
    \\.
    COPY repology.packages (effname, repo, family, arch, rawversion, origversion, cpe_vendor, cpe_product, srcname, binname, visiblename, links) FROM stdin;
    widget\trepo\tfamily\t\\N\t1.2\t1.2\t\\N\t\\N\twidget\t\\N\tWidget\t[[1, 1], [2, 2], [0, 1]]
    \\.
    """
    df, _, _ = read_dump(IOBuffer(dump))
    @test nrow(df) == 2 && all(df.multiple_urls)
    @test df.family == ["family", "family"]
    @test all(ismissing, df.binname) && df.visiblename == ["Widget", "Widget"]
    @test_throws ArgumentError read_dump(IOBuffer(replace(dump, "1\thttps" => "invalid\thttps")))
end
end

@testset "family-supported URL shapes" begin
    @test isnothing(Repology.pattern_winner(Dict("one" => Set(["family"]))))
    @test Repology.pattern_winner(Dict("one" => Set(["a", "b"]), "two" => Set(["c"]))) == "one"
    @test isnothing(Repology.pattern_winner(Dict("one" => Set(["a", "b"]), "two" => Set(["c", "d"]))))
    urls = Dict("https://example.org/widget-1.2.tar.gz" => ("widget", "1.2"),
        "https://example.org/widget-1.3.tar.gz" => ("widget", "1.3"))
    single = Dict(k => ["family"] for k in keys(urls))
    @test all(isempty, values(Repology.build_download_prefix_regex_map(urls, single)))
    multiple = Dict(k => ["a", "b"] for k in keys(urls))
    @test any(!isempty, values(Repology.build_download_prefix_regex_map(urls, multiple)))
    @test isempty(Repology.build_download_prefix_regex_map(urls, Dict{String,Vector{String}}()))
    @test any(!isempty, values(Repology.build_download_prefix_regex_map(urls, nothing)))
    keys_vector = collect(keys(urls))
    supporters = Dict(first(keys_vector) => ["a"], last(keys_vector) => ["b"])
    @test any(!isempty, values(Repology.build_download_prefix_regex_map(urls, supporters)))
end

@testset "independent version series" begin
    versions = Repology.known_versions()
    project = "test:mixed-version-series"
    versions[project] = Set(["b7000", "b8000", "b9000", "1.0", "1.1", "2.0"])
    try
        @test Repology.is_plausible_version(project, "b7821")
        @test !Repology.is_plausible_version(project, "b9002")
        @test Repology.is_plausible_version(project, "3.0")
        @test !Repology.is_plausible_version(project, "4.0")
        @test !Repology.is_plausible_version(project, "c7821")
        @test !Repology.is_plausible_version(project, "")
        @test !Repology.is_plausible_version(project, nothing)
    finally
        delete!(versions, project)
    end
end
