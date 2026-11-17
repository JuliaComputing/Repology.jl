"""
    Identification(project, version, provenance)

The result of [`identify`](@ref): a Repology project name and an upstream version, either of which may be
`nothing`, along with a `provenance` string describing how the result was obtained (see [`PROVENANCES`](@ref)).
"""
struct Identification
    project::Union{String,Nothing}
    version::Union{String,Nothing}
    provenance::Union{String,Nothing}
end
const UNIDENTIFIED = Identification(nothing, nothing, nothing)
Base.iterate(id::Identification, state=1) = state > 2 ? nothing : (getfield(id, state), state + 1)
Base.length(::Identification) = 2

"""
    PROVENANCES

The possible values of [`Identification`](@ref)'s `provenance`, in the order they are attempted. When a version is
identified, the provenance describes how the version was found; otherwise it describes how the project was found.

* `"override"`: a hand-verified entry in `overrides.toml`
* `"repology-url"`: an exact (or normalized) match of a download URL in Repology's data
* `"url-pattern"`: a curated URL pattern in `additional_info.toml`
* `"tag-scheme"`: a forge (e.g., GitHub) URL whose repository is known and whose tag parses as a version
* `"git-tag"`: a repository URL and commit, where the commit is tagged with a tag that parses as a version
* `"repository"`: a known repository, but no version could be determined
* `"heuristic"`: a URL that matches the shape of a known download URL with a different version number
"""
const PROVENANCES = ("override", "repology-url", "url-pattern", "tag-scheme", "git-tag", "repository", "heuristic")

const ADDITIONAL_INFO = Ref{Dict{String,Any}}()
additional_info() = isassigned(ADDITIONAL_INFO) ? ADDITIONAL_INFO[] :
    (ADDITIONAL_INFO[] = TOML.parsefile(joinpath(@__DIR__, "..", "additional_info.toml")))

const OVERRIDES = Ref{Dict{Tuple{String,String},Identification}}()
function overrides()
    isassigned(OVERRIDES) && return OVERRIDES[]
    data = Dict{Tuple{String,String},Identification}()
    for entry in get(TOML.parsefile(joinpath(@__DIR__, "..", "overrides.toml")), "override", [])
        version = get(entry, "version", nothing)
        data[(entry["url"], get(entry, "commit", ""))] = Identification(entry["project"], version, "override")
    end
    return OVERRIDES[] = data
end

const CURATED_URL_PATTERNS = Ref{Vector{Pair{Regex,String}}}()
function curated_url_patterns()
    isassigned(CURATED_URL_PATTERNS) && return CURATED_URL_PATTERNS[]
    pats = Pair{Regex,String}[]
    for (proj, info) in additional_info(), pat in get(info, "url_patterns", String[])
        push!(pats, Regex(pat) => proj)
    end
    return CURATED_URL_PATTERNS[] = pats
end

const CURATED_REPOSITORIES = Ref{Dict{String,String}}()
function curated_repositories()
    isassigned(CURATED_REPOSITORIES) && return CURATED_REPOSITORIES[]
    repos = Dict{String,String}()
    for (proj, info) in additional_info(), repo in get(info, "repositories", String[])
        repos[repo] = proj
        repos[normalize_url(repo)] = proj
    end
    return CURATED_REPOSITORIES[] = repos
end

const KNOWN_VERSIONS = Ref{Dict{String,Set{String}}}()
function known_versions()
    isassigned(KNOWN_VERSIONS) && return KNOWN_VERSIONS[]
    versions = Dict{String,Set{String}}()
    for (_, (proj, ver)) in download_data()
        push!(get!(versions, proj, Set{String}()), ver)
    end
    return KNOWN_VERSIONS[] = versions
end

leading_number(ver) = (m = match(r"^v?(\d+)", ver); isnothing(m) ? nothing : tryparse(BigInt, m.captures[1]))

"""
    is_plausible_version(project, version)

Check that `version` looks like a version number and is consistent with the versions Repology knows about for `project`.
Versions must start with a digit and must not contain underscores, slashes or whitespace (these are signs of a
munged tag name). If Repology knows at least three versions of the project, then the leading number of the version
must not exceed the largest known leading number by more than one. Repology only knows about currently-packaged
versions, so older versions are not rejected.
"""
function is_plausible_version(project, version)
    isnothing(version) && return false
    occursin(r"^\d[0-9A-Za-z.+~-]*$", version) || return false
    known = get(known_versions(), something(project, ""), Set{String}())
    version in known && return true
    majors = filter(!isnothing, leading_number.(collect(known)))
    length(majors) >= 3 || return true
    major = leading_number(version)
    return major <= maximum(majors) + 1
end

const RELEASE_QUALIFIERS = r"^(?:stable|release|final|src|source|orig)$"i
"""
    version_from_tag(project, tag)

Parse a version number out of a git tag name, using the project's `tag_patterns` from `additional_info.toml` if
it has them, or a generic parser otherwise. The generic parser finds the first token (after a prefix like `v`,
`R_`, `REL_`, `openssl-`, or `Release-`) that is entirely a version number, where the numeric components may
be separated by any one of `.`, `_` or `-` (normalized to `.`), followed by an optional qualifier like `p1`, `rc2`,
or `-stable` (release qualifiers like `-stable` are dropped). Returns `nothing` if the result is not plausible.
"""
function version_from_tag(project, tag)
    tag = String(strip(first(split(URIs_unescape(tag), '\n'))))
    for pat in get(get(additional_info(), something(project, ""), Dict()), "tag_patterns", [])
        r = Regex(pat["regex"])
        occursin(r, tag) || continue
        ver = replace(tag, r => SubstitutionString(get(pat, "version", "\\1")))
        return is_plausible_version(project, ver) ? ver : nothing
    end
    ver = parse_tag_version(tag)
    return is_plausible_version(project, ver) ? ver : nothing
end

function parse_tag_version(tag)
    # Candidate start positions: digits that don't continue a number (v1.2, R_2_8_3, cli-v2025.1.3, tectonic@0.11.0)
    starts = [i for i in eachindex(tag) if isdigit(tag[i]) && (i == 1 || !(tag[prevind(tag, i)] in "0123456789."))]
    for s in starts
        m = match(r"^(\d+)(?:([._-])(\d+)(?:\2\d+)*)?(?:([._-]?)([A-Za-z]+)(\d*))?$", SubString(tag, s))
        isnothing(m) && continue
        numeric = m.captures[2] === nothing ? m.captures[1] :
            replace(match(r"^\d+(?:[._-]\d+)*", SubString(tag, s)).match, m.captures[2] => ".")
        isnothing(m.captures[5]) && return numeric
        qualifier, n = lowercase(m.captures[5]), m.captures[6]
        occursin(RELEASE_QUALIFIERS, qualifier) && isempty(n) && return numeric
        sep = m.captures[4] in ("", "_") || qualifier == "p" ? "" : m.captures[4]
        return string(numeric, sep, qualifier, n)
    end
    return nothing
end

URIs_unescape(s) = replace(s, r"%([0-9A-Fa-f]{2})" => x -> string(Char(parse(UInt8, x[2:3]; base=16))))

"""
    (repo, tag) = forge_repository(url)

Split a GitHub or GitLab URL into the repository URL and a tag (or `nothing`) if the URL is a release download or
a tag archive.
"""
function forge_repository(url)
    m = match(r"^(?:https?|git)://(?:www\.)?github\.com/([^/]+)/([^/@#?]+)(.*)$", url)
    if !isnothing(m)
        owner, repo, rest = m.captures
        repo_url = string("https://github.com/", owner, "/", chopsuffix(repo, ".git"))
        rest = replace(rest, r"//+" => "/")
        t = match(r"^/(?:archive/refs/tags/releases|archive/refs/tags|archive/releases|archive)/([^/]+?)\.(?:tar\.gz|tar\.bz2|tar\.xz|tgz|zip)$", rest)
        isnothing(t) && (t = match(r"^/(?:releases/download|archive)/([^/]+)/[^/]+$", rest))
        return (repo_url, isnothing(t) ? nothing : String(t.captures[1]))
    end
    m = match(r"^https?://(gitlab\.[^/]+|salsa\.debian\.org|codeberg\.org)/(.+?)(?:\.git)?(/-/archive/([^/]+)/[^/]+|/archive/([^/]+?)\.(?:tar\.gz|zip))?/?$", url)
    if !isnothing(m)
        tag = something(m.captures[4], m.captures[5], Some(nothing))
        return (string("https://", m.captures[1], "/", m.captures[2]), tag === nothing ? nothing : String(tag))
    end
    return (nothing, nothing)
end

function repository_projects(url)
    isnothing(url) && return String[]
    repos, curated = repository_data(), curated_repositories()
    projs = String[]
    for u in (url, string(url, ".git"), normalize_url(url))
        haskey(curated, u) && push!(projs, curated[u])
        haskey(repos, u) && push!(projs, repos[u])
    end
    return unique!(projs)
end

# When a source could belong to several projects, prefer those that have a CPE (and so can be matched against
# advisories) and then those that aren't a language-specific repackaging (like python:foo or rust:foo)
project_rank(proj) = (haskey(cpe_data(), proj) ? 0 : 1, contains(proj, ':') ? 1 : 0)
best_project(projs) = isempty(projs) ? nothing : first(sort(projs, by=project_rank))

is_git_commit(hash) = !isnothing(hash) && occursin(r"^[0-9a-f]{40}$", hash)

"""
    identify(url; commit=nothing, use_overrides=true)

Identify the upstream Repology project and version for a source URL. If the URL is a git repository, also
pass the `commit` to look up its version via tags. Returns an [`Identification`](@ref); see [`PROVENANCES`](@ref)
for the order in which identification is attempted. Versions are only returned when they look like plausible
version numbers for the identified project.

Note that identifying versions from commits requires network access to the repository.
"""
function identify(url; commit=nothing, use_overrides=true)
    commit = is_git_commit(commit) ? commit : nothing
    if use_overrides
        o = overrides()
        haskey(o, (url, something(commit, ""))) && return o[(url, something(commit, ""))]
    end

    dls = download_data()
    for u in (url, normalize_url(url))
        haskey(dls, u) && return Identification(dls[u]..., "repology-url")
    end

    for (regex, proj) in curated_url_patterns()
        m = match(regex, url)
        isnothing(m) && continue
        ver = isempty(m.captures) || isnothing(m.captures[1]) ? nothing : String(m.captures[1])
        return is_plausible_version(proj, ver) ? Identification(proj, ver, "url-pattern") : Identification(proj, nothing, "repository")
    end

    repo, tag = forge_repository(url)
    projs = unique!([repository_projects(repo); repository_projects(url)])
    if !isempty(projs)
        h = heuristic_match(url)
        proj = best_project(isnothing(h) ? projs : unique!([projs; h.project]))
        if !isnothing(tag)
            ver = version_from_tag(proj, tag)
            isnothing(ver) || return Identification(proj, ver, "tag-scheme")
        end
        if !isnothing(commit)
            for t in tags_for_commit(something(repo, url), commit)
                ver = version_from_tag(proj, t)
                isnothing(ver) || return Identification(proj, ver, "git-tag")
            end
        end
        !isnothing(h) && h.project == proj && return h
        return Identification(proj, nothing, "repository")
    end

    return something(heuristic_match(url), UNIDENTIFIED)
end

function heuristic_match(url)
    prefix_regex_map = download_prefix_regex_map()
    for u in (url, normalize_url(url))
        idx = min(MAX_PREFIX_LENGTH, prevind(u, lastindex(u), 2))
        while idx > 5
            idx = prevind(u, idx)
            prefix = SubString(u, 1, idx)
            rest = SubString(u, nextind(u, idx))
            for (regex, proj) in get(prefix_regex_map, prefix, Pair{Regex,String}[])
                m = match(regex, rest)
                isnothing(m) && continue
                ver = String(m.captures[1])
                is_plausible_version(proj, ver) && return Identification(proj, ver, "heuristic")
            end
        end
    end
    return nothing
end

const _LS_REMOTE_CACHE = Dict{String,Dict{String,Vector{String}}}()
function remote_tags(repo)
    get!(_LS_REMOTE_CACHE, repo) do
        tags = Dict{String,Vector{String}}()
        out = try
            readchomp(pipeline(`git ls-remote --tags $repo`, stderr=devnull))
        catch ex
            @debug "failed to list tags for $repo" exception=ex
            ""
        end
        for line in split(out, '\n', keepempty=false)
            sha, ref = split(line, '\t')
            name = chopsuffix(chopprefix(ref, "refs/tags/"), "^{}")
            push!(get!(tags, sha, String[]), name)
        end
        tags
    end
end

"""
    tags_for_commit(repo, commit)

Return the tag names that point at `commit` in `repo` (or, failing that, at its first parent).
"""
function tags_for_commit(repo, commit; git_cache=_GIT_CACHE)
    tags = get(remote_tags(repo), commit, String[])
    isempty(tags) || return tags
    tag = get_tag_from_commit(repo, commit; git_cache)
    return isnothing(tag) ? String[] : split(tag, '\n', keepempty=false)
end
