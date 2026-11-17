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
    @test identify("https://github.com/libexpat/libexpat/releases/download/R_2_8_3/expat-2.8.3.tar.xz") == Identification("expat", "2.8.3", "url-pattern")
    @test identify("https://zlib.net/zlib-1.2.11.tar.gz") == Identification("zlib", "1.2.11", "repology-url")
    @test identify("https://github.com/libexpat/libexpat/releases/download/R_2_9_0/expat-2.9.0.tar.xz").version == "2.9.0"
    @test identify("https://github.com/wolfSSL/wolfssl/archive/refs/tags/v5.9.3-stable.tar.gz") == Identification("wolfssl", "5.9.3", "tag-scheme")
    @test identify("https://github.com/postgres/postgres/archive/refs/tags/REL_16_9.tar.gz") == Identification("postgresql", "16.9", "tag-scheme")
    @test identify("https://example.invalid/not-a-real-project-1.2.3.tar.gz") == Identification(nothing, nothing, nothing)
    for url in ("https://github.com/libexpat/libexpat/releases/download/R_2_8_3/expat-2.8.3.tar.xz",
                "https://github.com/postgres/postgres/archive/refs/tags/REL_16_9.tar.gz")
        @test identify(url).provenance in Repology.PROVENANCES
    end
    # Hand-verified sources take precedence over everything else
    Repology.overrides()[("https://example.invalid/override-1.0.tar.gz", "")] = Identification("example", "1.0", "override")
    @test identify("https://example.invalid/override-1.0.tar.gz") == Identification("example", "1.0", "override")
    @test identify("https://example.invalid/override-1.0.tar.gz"; use_overrides=false).provenance != "override"
    delete!(Repology.overrides(), ("https://example.invalid/override-1.0.tar.gz", ""))
    # Curated repositories take precedence over Repology's, and tag_patterns pick between projects sharing a repository
    @test Repology.repository_projects("https://github.com/open-policy-agent/opa") == ["openpolicyagent"]
    @test Repology.repository_projects("https://github.com/apache/tvm-ffi") == ["python:apache-tvm-ffi"]
    @test Repology.tag_project(["sdl2", "sdl3"], "release-2.32.10") == "sdl2"
    @test Repology.tag_project(["sdl2", "sdl3"], "release-3.2.0") == "sdl3"
    @test Repology.tag_project(["sdl2", "sdl3"], "prerelease-3.1.10") == "sdl3"
    @test Repology.tag_project(["sdl2", "sdl3"], "v3.2.0") === nothing
    @test Repology.version_from_tag("sdl3", "release-3.2.0") == "3.2.0"
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
    @test parse_tag_version("ImageMagick-7.1.1-47") === nothing
    @test parse_tag_version("processing-1434-4.5.6") == "4.5.6"
    @test parse_tag_version("RELEASE.2025-09-07T16-13-09Z") === nothing
    @test parse_tag_version("release.1.2.3") == "1.2.3"
    @test parse_tag_version("3a5f1c2") === nothing
    @test parse_tag_version("20190702") == "20190702"
    @test parse_tag_version("0123abc4567def") === nothing
    @test Repology.is_git_commit("3564038")
    @test !Repology.is_git_commit(repeat("a", 64))
    # Munged versions are never returned
    @test !Repology.is_plausible_version("expat", "8_3")
    @test !Repology.is_plausible_version("expat", "v2.8.3")
    @test !Repology.is_plausible_version("expat", nothing)
end

# A corpus of known-good source => (project, version) mappings, harvested from GeneralMetadata.jl by
# scripts/build_corpus.jl. "manual" entries were hand-corrected; "jll-version" entries are those whose upstream
# version equalled the JLL version. Both must match project and version exactly.
# Git sources (with a commit) require network access and are only checked if REPOLOGY_TEST_NETWORK is set.
@testset "vercmp" begin
    using Repology: vercmp, version_scheme, version_features, VersionScheme, P_IS_PATCH
    # libversion defaults
    @test vercmp("1.2.0-dev", "1.2.0") == -1
    @test vercmp("1.2.0-rc1", "1.2.0") == -1
    @test vercmp("7.1.2-1", "7.1.2") == 1
    @test vercmp("1.10", "1.9") == 1
    @test vercmp("7.1.2-9", "7.1.2.9") == 0
    @test vercmp("9.2p1", "9.2") == -1
    @test vercmp("9.2p1", "9.2"; flags=P_IS_PATCH) == 1

    @test version_features("1.2.3") == Set()
    @test version_features("1.2.3-rc1") == Set()
    @test version_features("7.1.2-1") == Set([:hyphen_number])
    @test version_features("9.2p1") == Set([:p_number])
    @test version_features("1.0.2u") == Set([:letter_suffix])
    @test version_features("1.2a1") == Set([:word])
    @test version_features("1.2foo") == Set([:word])

    # Unambiguous versions compare without knowing anything about the project
    @test vercmp(nothing, "1.10", "1.9") == 1
    @test vercmp(nothing, "2.0.0-rc1", "2.0.0") == -1
    @test vercmp("expat", "2.8.3", "2.10.0") == -1
    # Ambiguous ones need a scheme
    @test vercmp(nothing, "1.2.0-1", "1.2.0") === nothing
    @test vercmp(nothing, "9.2p1", "9.2") === nothing
    @test vercmp("expat", "2.8.3-1", "2.8.3") === nothing
    # Curated schemes
    @test vercmp("imagemagick", "7.1.2-1", "7.1.2") == 1
    @test vercmp("imagemagick", "7.1.2-10", "7.1.2-9") == 1
    @test vercmp("openssh", "9.2p1", "9.2") == 1
    @test vercmp("openssh", "9.3", "9.2p2") == 1
    semver = VersionScheme(:semver, 0, true, Set{Symbol}())
    @test vercmp(semver, "1.2.0-1", "1.2.0") == -1
    @test vercmp(semver, "1.2.0-dev", "1.2.0") == -1
    @test vercmp(semver, "1.2.0+build", "not a version") === nothing
    @test vercmp(semver, "1.2.0+build.1", "1.2.0+build.2") == 0
    @test vercmp(semver, "1.2.0+build", "1.2.0") == 0
    @test vercmp(semver, "1.2.1+build", "1.2.0") == 1
    # Inferred schemes follow the forms a project has already released
    inferred = VersionScheme(:libversion, 0, false, Set([:hyphen_number]))
    @test vercmp(inferred, "7.1.2-1", "7.1.2") == 1
    @test vercmp(inferred, "9.2p1", "9.2") === nothing
    scheme = version_scheme("imagemagick")
    @test scheme.curated && scheme.kind === :libversion
    @test version_scheme("openssh").flags == P_IS_PATCH
    @test !version_scheme("expat").curated
end

@testset "corpus" begin
    corpus = TOML.parsefile(joinpath(@__DIR__, "corpus.toml"))["entry"]
    known_failures = Set((e["url"], get(e, "hash", "")) for e in get(TOML.parsefile(joinpath(@__DIR__, "known_failures.toml")), "failure", []))
    network = !isempty(get(ENV, "REPOLOGY_TEST_NETWORK", ""))
    # Set when refreshing data, so that newly-fixed known failures don't block the refresh (only regressions do)
    allow_fixed = !isempty(get(ENV, "REPOLOGY_ALLOW_FIXED", ""))
    for e in corpus
        haskey(e, "hash") && !network && continue
        id = identify(e["url"]; commit=get(e, "hash", nothing), use_overrides=false)
        ok = id.version == e["version"] && id.project == e["project"]
        if (e["url"], get(e, "hash", "")) in known_failures
            allow_fixed && ok ? (@test ok) : (@test_broken ok)
        else
            ok || @info "corpus mismatch" e id
            @test ok
        end
    end
end
