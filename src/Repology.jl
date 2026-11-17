module Repology

using TOML: TOML
using DataStructures: OrderedDict
using Artifacts: artifact_hash, artifact_path

"""
    data_dir()

The directory with the data exported from Repology's database dump (`repositories.toml`, `downloads.toml` and
`cpes.toml`). It's the `repology_data` artifact, or the `REPOLOGY_DATA` environment variable if set (used when
testing a refresh before it's published). Until the first artifact is published, it's the `data` directory of this
repository.
"""
function data_dir()
    isempty(get(ENV, "REPOLOGY_DATA", "")) || return ENV["REPOLOGY_DATA"]
    hash = artifact_hash("repology_data", joinpath(@__DIR__, "..", "Artifacts.toml"))
    isnothing(hash) && return joinpath(@__DIR__, "..", "data")
    return artifact_path(hash)
end

const REPOSITORY_DATA = Ref{Dict{String,String}}()
function repository_data()
    isassigned(REPOSITORY_DATA) && return REPOSITORY_DATA[]
    data = TOML.parsefile(joinpath(data_dir(), "repositories.toml"))
    for (k,v) in sort!(collect(data), by=first)
        # also store normalized URLs directly for matching
        data[normalize_url(k)] = v
    end
    return REPOSITORY_DATA[] = data
end
const DOWNLOAD_DATA = Ref{Dict{String,Tuple{String,String}}}()
function download_data()
    isassigned(DOWNLOAD_DATA) && return DOWNLOAD_DATA[]
    data = Dict{String,Tuple{String,String}}()
    # Iterate in sorted order so that collisions between normalized URLs resolve the same way on every Julia version
    for (k,v) in sort!(collect(TOML.parsefile(joinpath(data_dir(), "downloads.toml"))), by=first)
        data[k] = (v[1], v[2])
        data[normalize_url(k)] = (v[1], v[2])
    end
    return DOWNLOAD_DATA[] = data
end
# Count how many known downloads support each project for a given prefix/regex pair
vote!(map, prefix, pattern, project) =
    (votes = get!(Dict{String,Int}, get!(Dict{String,Dict{String,Int}}, map, prefix), pattern);
     votes[project] = get(votes, project, 0) + 1)

# Different projects sharing a prefix/regex pair are usually a bad alias in a single repository (like rsync3 for
# rsync); use the pattern only when one project has at least twice the support of all others combined.
function pattern_winner(votes)
    best = argmax(p -> (votes[p], p), keys(votes))
    return 2 * (sum(values(votes)) - votes[best]) <= votes[best] ? best : nothing
end

const DOWNLOAD_PREFIX_REGEX_MAP = Ref{Dict{String,Vector{Pair{Regex,String}}}}()
const MAX_PREFIX_LENGTH = 120
function download_prefix_regex_map()
    isassigned(DOWNLOAD_PREFIX_REGEX_MAP) && return DOWNLOAD_PREFIX_REGEX_MAP[]
    map = Dict{String,Dict{String,Dict{String,Int}}}()
    for (k,v) in sort!(collect(download_data()), by=first)
        version = chopprefix(v[2], "v") # drop an optional v prefix
        length(version) >= 3 || continue # ensure non-trivial version numbers
        version[1] in '0':'9' || continue # ensure version starts with a digit

        # There are three very common cases:
        # * The version number appears exactly once or more
        # * The version number appears once and a _subset_ (often just major/minor) or _munged_ flavor of it appears a second time
        #   - these often appear _before_ the real version number
        idx = findfirst(version, k)
        idx === nothing && continue # ensure the version number appears in the URL at least once
        prefix, rest = SubString(k, 1, prevind(k, idx[1])), SubString(k, idx[1])
        length(prefix) > MAX_PREFIX_LENGTH && continue # skip absurdly long prefixes

        # Now we transform rest into a regular expression to match the version number one or more times
        vpat = replace(replace(rest, version => "\\E(.*?)\\Q"; count=1), version => "\\E\\1\\Q")
        pattern = string("^\\Q", vpat, "\\E\$")

        vote!(map, prefix, pattern, v[1])

        # Now, secondarily, if a non-trivial prefix of the version number appears in the prefix, we also support that.
        munged_version = version
        while (munged_version = munged_version[1:prevind(munged_version, end)]; length(munged_version) >= 3)
            if contains(prefix, munged_version)
                idx = findfirst(munged_version, k)
                prefix, rest = SubString(k, 1, prevind(k, idx[1])), SubString(k, idx[1])
                vpat = replace(replace(rest, version => "\\E(.*?)\\Q"; count=1), version => "\\E\\1\\Q")
                vpat = replace(vpat, munged_version => "\\E.{$(length(munged_version))}\\Q") # just do a fixed-width wildcard
                pattern = string("^\\Q", vpat, "\\E\$")

                vote!(map, prefix, pattern, v[1])
                break
            end
        end
    end
    regex_map = Dict{String, Vector{Pair{Regex,String}}}()
    for (prefix, patterns) in map
        # Sort the suffixes by length so we always match the longest one first
        regex_map[prefix] = Pair{Regex,String}[Regex(p) => project
            for (p, votes) in sort!(collect(patterns), by=((p, _),)->(-length(p), p))
            for project in (pattern_winner(votes),) if !isnothing(project)]
    end
    return DOWNLOAD_PREFIX_REGEX_MAP[] = regex_map
end

const CPE_DATA = Ref{Dict{String,Any}}()
function cpe_data()
    isassigned(CPE_DATA) && return CPE_DATA[]
    return CPE_DATA[] = TOML.parsefile(joinpath(data_dir(), "cpes.toml"))
end

"""
    normalize_url(url)

Given a URL, strip the scheme (e.g., https:// or git://) and known/common extension suffixes
"""
function normalize_url(url)
    # TODO: it'd be nice to also support normalizing Gentoo/Pacman mirror:// style URLs and known mirrors
    return lowercase(url) |>
        x->chopprefix(x, r"^[^:]+://(www\.|ftp\.)?") |>
        x->chopsuffix(x, r"(?:\.tar)?\.(?:gz|bz2|xz|zip|bzip2|tgz|tbz2|git)(?:/download)?$") |>
        x->replace(x, r"//+" => "/")
end

const _GIT_CACHE = Dict{String,String}()
"""
    get_tag_from_commit(repo, commit; git_cache, include_parent=true)

Clone `repo` (without blobs) and return the newline-separated tags that point at `commit` (or its first parent),
or `nothing` if there are none.
"""
function get_tag_from_commit(repo, commit; git_cache=_GIT_CACHE, include_parent=true)
    try
        dir = get!(git_cache, repo) do
            tmp = mktempdir()
            run(pipeline(`git clone --filter=tree:0 --no-checkout --tags $repo $tmp`, stdout=Base.devnull, stderr=Base.devnull))
            tmp
        end
        tag = cd(dir) do
            buf = IOBuffer()
            for c in (include_parent ? (commit, commit*"~") : (commit,))
                if success(pipeline(`git tag --points-at $c`, stdout=buf, stderr=Base.devnull)) && position(buf) > 0
                    return String(take!(buf))
                end
                seekstart(buf)
                if success(pipeline(`git fetch origin $c`, stdout=Base.devnull, stderr=Base.devnull)) &&
                    success(pipeline(`git tag --points-at $c`, stdout=buf, stderr=Base.devnull)) && position(buf) > 0
                    return String(take!(buf))
                end
                seekstart(buf)
            end
            return ""
        end
        return isempty(strip(tag)) ? nothing : strip(tag)
    catch ex
        @debug "failed to get tags for $commit in $repo" exception=ex
        return nothing
    end
end

include("identify.jl")

"""
    (project, version) = identify_upstream(url, hash)

Given a URL and a hash, attempt to identify the upstream project and version using data from Repology.

If no project is found, returns `(nothing, nothing)`, and it may return `(proj, nothing)` if no version info is available.
This is a thin wrapper around [`identify`](@ref), which also reports the provenance of the identification.

Note that for repositories, it will attempt to download the git repository for versioning/tag information.
"""
function identify_upstream(url, hash)
    id = identify(url; commit=hash)
    return (id.project, id.version)
end

end
