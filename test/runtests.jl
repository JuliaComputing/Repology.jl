using Repology
using Repology: Identification, identify, parse_tag_version
using TOML
using Test

@testset "identify_upstream" begin
    @test Repology.identify_upstream("https://www.cairographics.org/releases/cairo-1.32.0.tar.xz", "") == ("cairo-graphics-library", "1.32.0")
    @test Repology.identify_upstream("https://download.gnome.org/sources/glib-networking/2.74/glib-networking-2.74.0.tar.xz", "") == ("glib-networking", "2.74.0")
    @test Repology.identify_upstream("https://downloads.sourceforge.net/project/gnuplot/gnuplot/6.0.3/gnuplot-6.0.3.tar.gz", "") == ("gnuplot", "6.0.3")
    @test Repology.identify_upstream("https://sourceforge.net/projects/graphicsmagick/files/graphicsmagick/1.3.45/GraphicsMagick-1.3.45.tar.xz", "") == ("graphicsmagick", "1.3.45")
    @test Repology.identify_upstream("https://sourceforge.net/projects/libpng/files/libpng16/1.6.54/libpng-1.6.54.tar.gz", "") == ("libpng", "1.6.54")

    @test Repology.identify_upstream("https://github.com/libexpat/libexpat/releases/download/R_2_2_7/expat-2.2.7.tar.xz", "") == ("expat", "2.2.7")
    @test Repology.identify_upstream("https://github.com/Singular/Singular/releases/download/Release-4-4-1p5/singular-4.4.1p5.tar.gz", "") == ("singular", "4.4.1p5")
end

@testset "identify provenance" begin
    @test identify("https://github.com/libexpat/libexpat/releases/download/R_2_8_3/expat-2.8.3.tar.xz") == Identification("expat", "2.8.3", "repology-url")
    @test identify("https://github.com/libexpat/libexpat/releases/download/R_2_9_0/expat-2.9.0.tar.xz").version == "2.9.0"
    @test identify("https://github.com/wolfSSL/wolfssl/archive/refs/tags/v5.9.3-stable.tar.gz") == Identification("wolfssl", "5.9.3", "tag-scheme")
    @test identify("https://github.com/postgres/postgres/archive/refs/tags/REL_16_9.tar.gz") == Identification("postgresql", "16.9", "tag-scheme")
    @test identify("https://example.invalid/not-a-real-project-1.2.3.tar.gz") == Identification(nothing, nothing, nothing)
    for url in ("https://github.com/libexpat/libexpat/releases/download/R_2_8_3/expat-2.8.3.tar.xz",
                "https://github.com/postgres/postgres/archive/refs/tags/REL_16_9.tar.gz")
        @test identify(url).provenance in Repology.PROVENANCES
    end
    # Overrides take precedence over everything else
    Repology.overrides()[("https://example.invalid/override-1.0.tar.gz", "")] = Identification("example", "1.0", "override")
    @test identify("https://example.invalid/override-1.0.tar.gz") == Identification("example", "1.0", "override")
    @test identify("https://example.invalid/override-1.0.tar.gz"; use_overrides=false).provenance != "override"
    delete!(Repology.overrides(), ("https://example.invalid/override-1.0.tar.gz", ""))
end

@testset "tag parsing" begin
    for (tag, ver) in ("R_2_8_3" => "2.8.3", "REL_16_9" => "16.9", "V_9_2_P1" => "9.2p1", "v5.9.3-stable" => "5.9.3",
                       "Release_2022_09_1" => "2022.09.1", "PCRE2-10.42" => "10.42", "openssl-3.5.8" => "3.5.8",
                       "v1.10.0-rc3" => "1.10.0-rc3", "llvmorg-17.0.6" => "17.0.6", "cares-1_34_5" => "1.34.5",
                       "Release-4-4-1p5" => "4.4.1p5", "tectonic@0.11.0" => "0.11.0", "v2.0" => "2.0", "7" => "7")
        @test parse_tag_version(tag) == ver
    end
    @test parse_tag_version("nightly") === nothing
    @test parse_tag_version("7.1.2-1") === nothing
    @test parse_tag_version("3a5f1c2") === nothing
    @test parse_tag_version("0123abc4567def") === nothing
    @test Repology.is_git_commit("3564038")
    @test !Repology.is_git_commit(repeat("a", 64))
    # Munged versions are never returned
    @test !Repology.is_plausible_version("expat", "8_3")
    @test !Repology.is_plausible_version("expat", "v2.8.3")
    @test !Repology.is_plausible_version("expat", nothing)
end

# A corpus of known-good source => (project, version) mappings, harvested from GeneralMetadata.jl by
# scripts/build_corpus.jl. "manual" entries were hand-corrected and must match exactly; "jll-version" entries
# are those whose upstream version equalled the JLL version, so only the version is checked.
# Git sources (with a commit) require network access and are only checked if REPOLOGY_TEST_NETWORK is set.
@testset "corpus" begin
    corpus = TOML.parsefile(joinpath(@__DIR__, "corpus.toml"))["entry"]
    known_failures = Set((e["url"], get(e, "hash", "")) for e in get(TOML.parsefile(joinpath(@__DIR__, "known_failures.toml")), "failure", []))
    network = !isempty(get(ENV, "REPOLOGY_TEST_NETWORK", ""))
    # Set when refreshing data, so that newly-fixed known failures don't block the refresh (only regressions do)
    allow_fixed = !isempty(get(ENV, "REPOLOGY_ALLOW_FIXED", ""))
    for e in corpus
        haskey(e, "hash") && !network && continue
        id = identify(e["url"]; commit=get(e, "hash", nothing), use_overrides=false)
        ok = id.version == e["version"] && (e["kind"] != "manual" || id.project == e["project"])
        if (e["url"], get(e, "hash", "")) in known_failures
            allow_fixed && ok ? (@test ok) : (@test_broken ok)
        else
            ok || @info "corpus mismatch" e id
            @test ok
        end
    end
end
