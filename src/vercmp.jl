using libversion_jll: libversion

# Flags from libversion's version.h
const P_IS_PATCH = Cint(0x1)
const ANY_IS_PATCH = Cint(0x2)
const LOWER_BOUND = Cint(0x4)
const UPPER_BOUND = Cint(0x8)
const VERSION_FLAGS = Dict("P_IS_PATCH" => P_IS_PATCH, "ANY_IS_PATCH" => ANY_IS_PATCH)

"""
    vercmp(a, b; flags=0, a_flags=flags, b_flags=flags)

Compare two version strings with [libversion](https://github.com/repology/libversion), the comparator Repology
uses, returning -1, 0, or 1. This ignores any project-specific version scheme; see `vercmp(project, a, b)`.
"""
vercmp(a::AbstractString, b::AbstractString; flags=0, a_flags=flags, b_flags=flags) =
    Int(ccall((:version_compare4, libversion), Cint, (Cstring, Cstring, Cint, Cint), a, b, a_flags, b_flags))

"""
    VersionScheme(kind, flags, curated, features)

How a project's versions compare. `kind` is `:libversion` (compared with `flags`) or `:semver` (compared as
`VersionNumber`s). A `curated` scheme comes from `version_scheme` and/or `version_flags` in `additional_info.toml`
and is trusted for all versions. Otherwise the scheme is inferred from the versions Repology knows about, and
`features` lists the ambiguous version features (see [`version_features`](@ref)) the project uses in its releases.
"""
struct VersionScheme
    kind::Symbol
    flags::Cint
    curated::Bool
    features::Set{Symbol}
end

const UNAMBIGUOUS_WORDS = r"^(?:alpha|beta|rc|pre|dev|post|patch|pl|errata)$"
"""
    version_features(version)

The parts of `version` whose ordering depends on the project's version scheme:

* `:hyphen_number`: a number after a hyphen, like `7.1.2-1`. libversion (and ImageMagick) order this after `7.1.2`,
  but SemVer orders it before (as a pre-release).
* `:p_number`: `p` followed by a number, like OpenSSH's `9.2p1`. libversion orders this before `9.2` unless given
  `P_IS_PATCH`.
* `:letter_suffix`: a single letter after a number, like OpenSSL's `1.0.2u`. libversion orders this after `1.0.2`.
* `:word`: any other word, like `1.2a1` or `1.2foo`. libversion orders these before `1.2` unless given `ANY_IS_PATCH`.

Pre-release (`alpha`, `beta`, `rc`, `pre`, `dev`) and post-release (`post`, `patch`, `pl`, `errata`) words are
not ambiguous.
"""
function version_features(version)
    v = lowercase(version)
    features = Set{Symbol}()
    occursin(r"\d-\d", v) && push!(features, :hyphen_number)
    for m in eachmatch(r"[a-z]+", v)
        word, next = m.match, m.offset + ncodeunits(m.match)
        before = m.offset > 1 ? v[prevind(v, m.offset)] : ' '
        followed_by_digit = next <= ncodeunits(v) && isdigit(v[next])
        if occursin(UNAMBIGUOUS_WORDS, word)
            continue
        elseif word == "p" && followed_by_digit
            push!(features, :p_number)
        elseif length(word) == 1 && isdigit(before) && !followed_by_digit
            push!(features, :letter_suffix)
        else
            push!(features, :word)
        end
    end
    return features
end

# Features whose meaning can be inferred from a project's releases: a feature in a packaged release is a release
# component, which libversion orders after the base version (`p` needs P_IS_PATCH for that)
const INFERABLE_FEATURES = (:hyphen_number, :p_number, :letter_suffix)

"""
    version_scheme(project)

The [`VersionScheme`](@ref) for `project`, either curated in `additional_info.toml` or inferred from the versions
Repology knows about.
"""
function version_scheme(project)
    info = get(additional_info(), something(project, ""), Dict{String,Any}())
    if haskey(info, "version_scheme") || haskey(info, "version_flags")
        kind = Symbol(get(info, "version_scheme", "libversion"))
        kind in (:libversion, :semver) || throw(ArgumentError("unknown version_scheme $kind for $project"))
        flags = reduce(|, (VERSION_FLAGS[f] for f in get(info, "version_flags", String[])); init=Cint(0))
        return VersionScheme(kind, flags, true, Set{Symbol}())
    end
    features = Set{Symbol}()
    for v in get(known_versions(), something(project, ""), ())
        union!(features, version_features(v))
    end
    intersect!(features, INFERABLE_FEATURES)
    return VersionScheme(:libversion, :p_number in features ? P_IS_PATCH : Cint(0), false, features)
end

"""
    vercmp(project, a, b)

Compare two upstream versions of `project` according to its [`version_scheme`](@ref), returning -1, 0, 1, or
`nothing` if the scheme cannot order them. Versions without ambiguous parts (like `1.2.3` or `1.2.3-rc1`) are always
compared. Otherwise, unless the scheme is curated, every ambiguous part (see [`version_features`](@ref)) must also
appear in the project's known releases; e.g., `7.1.2-1` is only compared if the project has released versions
with a hyphenated number.
"""
vercmp(project::Union{AbstractString,Nothing}, a::AbstractString, b::AbstractString) =
    vercmp(version_scheme(project), a, b)
function vercmp(scheme::VersionScheme, a::AbstractString, b::AbstractString)
    if scheme.kind === :semver
        va, vb = tryparse(VersionNumber, a), tryparse(VersionNumber, b)
        (isnothing(va) || isnothing(vb)) && return nothing
        # SemVer precedence ignores build metadata, but VersionNumber comparisons don't
        precedence(v) = VersionNumber(v.major, v.minor, v.patch, v.prerelease, ())
        return cmp(precedence(va), precedence(vb))
    end
    scheme.curated || (version_features(a) ⊆ scheme.features && version_features(b) ⊆ scheme.features) || return nothing
    return vercmp(a, b; flags=scheme.flags)
end
