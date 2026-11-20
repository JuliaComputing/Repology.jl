using TOML: TOML
using Repology: Repology
using DataStructures: DefaultDict, DefaultOrderedDict, OrderedDict
using DataFrames: DataFrames, DataFrame, groupby, combine, transform, eachrow, nrow, select!, Not

const DUMP_URL = "https://dumps.repology.org/repology-database-dump-latest.sql.zst"

# Values in a COPY ... FROM stdin block are tab-separated, with \\N for NULL and backslash escapes
copy_value(s) = s == "\\N" ? missing : occursin('\\', s) ? unescape_string(s) : String(s)

"""
    read_dump(io)

Stream Repology's SQL dump and keep only what we need from the `links`, `packages` and `manual_cpes` tables. This
avoids restoring the full dump (tens of GB) into PostgreSQL.
"""
function read_dump(io)
    links = Dict{Int32,String}()
    pkgs = (link_type=Int8[], link_id=Int32[], repo=String[], family=String[], effname=String[],
        srcname=Union{String,Missing}[], binname=Union{String,Missing}[], visiblename=Union{String,Missing}[],
        multiple_urls=Bool[], rawversion=String[], arch=Union{String,Missing}[], origversion=String[])
    pkg_cpes = Set{Tuple{String,String}}()
    manual_cpes = Tuple{String,String}[]
    intern = Dict{String,String}()
    table, cols = "", Dict{String,Int}()
    for line in eachline(io)
        if isempty(table)
            m = match(r"^COPY repology\.(\w+) \((.*)\) FROM stdin;$", line)
            isnothing(m) && continue
            table = m.captures[1] in ("links", "packages", "manual_cpes") ? m.captures[1] : "skip"
            cols = Dict(strip(c, ['"', ' ']) => i for (i, c) in enumerate(split(m.captures[2], ", ")))
            continue
        end
        line == "\\." && (table = ""; continue)
        table == "skip" && continue
        f = split(line, '\t')
        if table == "links"
            links[parse(Int32, f[cols["id"]])] = copy_value(f[cols["url"]])
        elseif table == "packages"
            effname = get!(intern, f[cols["effname"]], f[cols["effname"]])
            vendor, product = copy_value(f[cols["cpe_vendor"]]), copy_value(f[cols["cpe_product"]])
            !ismissing(vendor) && !ismissing(product) && push!(pkg_cpes, (effname, "$vendor:$product"))
            repo = get!(intern, f[cols["repo"]], f[cols["repo"]])
            family = get!(intern, f[cols["family"]], f[cols["family"]])
            names = map(("srcname", "binname", "visiblename")) do field
                value = copy_value(f[cols[field]])
                ismissing(value) ? missing : get!(intern, value, value)
            end
            arch = copy_value(f[cols["arch"]])
            arch = ismissing(arch) ? missing : get!(intern, arch, arch)
            rawversion, origversion = copy_value(f[cols["rawversion"]]), copy_value(f[cols["origversion"]])
            source_links = [(parse(Int8, m.captures[1]), parse(Int32, m.captures[2]))
                for m in eachmatch(r"\[(\d+), (\d+)", f[cols["links"]]) if m.captures[1] in ("1", "2")]
            multiple_urls = length(unique(last.(source_links))) > 1
            for (t, id) in source_links
                push!(pkgs.link_type, t); push!(pkgs.link_id, id)
                push!(pkgs.repo, repo); push!(pkgs.effname, effname); push!(pkgs.rawversion, rawversion)
                push!(pkgs.arch, arch); push!(pkgs.origversion, origversion)
                push!(pkgs.family, family); push!(pkgs.srcname, names[1]); push!(pkgs.binname, names[2])
                push!(pkgs.visiblename, names[3]); push!(pkgs.multiple_urls, multiple_urls)
            end
        elseif table == "manual_cpes"
            vendor, product = copy_value(f[cols["cpe_vendor"]]), copy_value(f[cols["cpe_product"]])
            !ismissing(vendor) && !ismissing(product) && push!(manual_cpes, (String(f[cols["effname"]]), "$vendor:$product"))
        end
    end
    df = DataFrame(pkgs)
    df.url = [links[id] for id in df.link_id]
    select!(df, Not(:link_id))
    return df, pkg_cpes, manual_cpes
end

source_name(s) = replace(lowercase(s), r"[^a-z0-9]" => "")

function basename_agrees(url, srcname, version)
    ismissing(srcname) && return false
    base = last(split(Repology.normalize_url(url), '/'))
    if !isempty(version)
        idx = findfirst(lowercase(version), base)
        isnothing(idx) || (base = base[1:prevind(base, first(idx))])
    end
    base = replace(base, r"[-_.]v?$" => "")
    return !isempty(base) && source_name(base) == source_name(last(split(srcname, '/')))
end

function resolve_claimants(df, rows; singleton_support=false)
    support = Dict{String,Set{String}}()
    for i in rows
        families = get!(Set{String}, support, df.effname[i])
        singleton_support && df.multiple_urls[i] && continue
        push!(families, df.family[i])
    end
    greatest = maximum(length, values(support))
    greatest == 0 && return nothing, support
    best = sort!([p for (p, families) in support if length(families) == greatest])
    length(best) == 1 && return only(best), support
    matches = [p for p in best if any(i -> df.effname[i] == p &&
        (!singleton_support || !df.multiple_urls[i]) &&
        basename_agrees(df.url[i], df.srcname[i], df.link_type[i] == 1 ? df.origversion[i] : ""), rows)]
    return length(matches) == 1 ? only(matches) : nothing, support
end

function write_ambiguity(io, df, rows, url, reason)
    isnothing(io) && return
    claimants = [Dict{String,Any}("project" => df.effname[i], "repo" => df.repo[i],
        "family" => df.family[i], "url" => df.url[i], "version" => df.origversion[i],
        "srcname" => coalesce(df.srcname[i], ""), "binname" => coalesce(df.binname[i], ""),
        "visiblename" => coalesce(df.visiblename[i], ""), "multiple_urls" => df.multiple_urls[i]) for i in rows]
    TOML.print(io, Dict("ambiguous" => [Dict("url" => url, "link_types" => sort!(unique(df.link_type[rows])),
        "reason" => reason, "claimants" => claimants)]); sorted=true)
end

function gather_links(df; singleton_support=false, diagnostics=nothing)
    candidates = Dict{String,Vector{Int}}()
    normalized = Dict{String,String}()
    for i in 1:nrow(df)
        url = get!(normalized, df.url[i]) do
            Repology.normalize_url(df.url[i])
        end
        push!(get!(Vector{Int}, candidates, url), i)
    end
    downloads = Dict{String,Pair{String,String}}()
    repositories = Dict{String,String}()
    families = Dict{String,Vector{String}}()
    ambiguous = 0
    for (url, rows) in candidates
        project, support = resolve_claimants(df, rows; singleton_support)
        if isnothing(project)
            ambiguous += 1
            write_ambiguity(diagnostics, df, rows, url, "project")
            continue
        end
        aliases = unique!([url; df.url[rows]])
        if any(i -> df.link_type[i] == 2, rows)
            for alias in aliases
                repositories[alias] = project
            end
        end
        if any(i -> df.link_type[i] == 1, rows)
            versions = unique(df.origversion[i] for i in rows if df.effname[i] == project && df.link_type[i] == 1)
            explicit = filter(v -> !isempty(v) && contains(lowercase(url), lowercase(v)), versions)
            version = length(explicit) == 1 ? only(explicit) :
                length(versions) == 1 && !occursin(r"\d", only(versions)) ? only(versions) : ""
            if isempty(version)
                ambiguous += 1
                write_ambiguity(diagnostics, df, rows, url, "version")
            end
            for alias in aliases
                downloads[alias] = project => version
                families[alias] = sort!(collect(support[project]))
            end
        end
    end
    return (; downloads, repositories, families, seen=Set(values(normalized)), ambiguous)
end

function retain_unclaimed(old, current, seen)
    return merge(filter(p -> !(Repology.normalize_url(first(p)) in seen), old), current)
end

function gather_cpes(pkg_cpes, manual_cpes)
    cpes = Dict{String,Vector{String}}()
    for (effname, cpe) in sort!(collect(pkg_cpes))
        push!(get!(cpes, effname, String[]), cpe)
    end
    # And now override those with manual entries, if they exist:
    cpe_overrides = Dict{String,Vector{String}}()
    for (effname, cpe) in manual_cpes
        push!(get!(cpe_overrides, effname, String[]), cpe)
    end
    merge!(cpes, cpe_overrides)
    return cpes
end

# A refresh that moves an already-exported URL to a different project needs review, so list those as a Markdown table
function write_project_changes(file, candidates...)
    changes = sort!([c for cs in candidates for c in cs if c[2] != c[3]])
    @info "$(length(changes)) exported URLs changed project"
    isempty(file) && return
    open(file, "w") do io
        isempty(changes) && return
        println(io, "| URL | before | after |\n|---|---|---|")
        foreach(((url, old, new),) -> println(io, "| ", url, " | `", old, "` | `", new, "` |"), changes)
    end
end

function main(dump=DUMP_URL)
    @info "reading $dump"
    df, pkg_cpes, manual_cpes = open(pipeline(isfile(dump) ? `cat $dump` : `curl -sSfL $dump`, `zstd -dc`)) do io
        read_dump(io)
    end
    @info "read $(nrow(df)) package links"
    return export_data(df, pkg_cpes, manual_cpes)
end

function export_data(df, pkg_cpes, manual_cpes; data=ENV["REPOLOGY_DATA_OUT"],
    mode=get(ENV, "REPOLOGY_SUPPORT_MODE", "all"),
    diagnostic_path=get(ENV, "REPOLOGY_DIAGNOSTICS", data * "-ambiguous.toml"))
    mkpath(data)
    mode in ("all", "singleton") || error("REPOLOGY_SUPPORT_MODE must be all or singleton")
    result = open(diagnostic_path, "w") do io
        gather_links(df; singleton_support=mode == "singleton", diagnostics=io)
    end
    downloads, repositories = result.downloads, result.repositories
    cpes = gather_cpes(pkg_cpes, manual_cpes)

    existing(file) = TOML.parsefile(joinpath(Repology.data_dir(), file))
    old_downloads = Dict(k => (v[1] => v[2]) for (k,v) in existing("downloads.toml"))
    old_repositories = Dict{String,String}(existing("repositories.toml"))
    write_project_changes(get(ENV, "REPOLOGY_PROJECT_CHANGES", ""),
        [(url, first(old_downloads[url]), first(p)) for (url, p) in downloads if haskey(old_downloads, url)],
        [(url, old_repositories[url], p) for (url, p) in repositories if haskey(old_repositories, url)])
    downloads = retain_unclaimed(old_downloads, downloads, result.seen)
    repositories = retain_unclaimed(old_repositories, repositories, result.seen)
    old_support_path = joinpath(Repology.data_dir(), "download_families.toml")
    old_support = isfile(old_support_path) ? TOML.parsefile(old_support_path) : Dict{String,Any}()
    support = retain_unclaimed(old_support, result.families, result.seen)
    cpes = merge(Dict{String,Vector{String}}(k => String.(v) for (k,v) in existing("cpes.toml")), cpes)

    header = "# This file is autogenerated with data from https://repology.com"
    open("$data/repositories.toml", "w") do io
        println(io, header)
        TOML.print(io, repositories, sorted=true)
    end
    open("$data/downloads.toml", "w") do io
        println(io, header)
        TOML.print(io, Dict(k=>[v...] for (k,v) in downloads), sorted=true)
    end
    open("$data/cpes.toml", "w") do io
        println(io, header)
        TOML.print(io, cpes, sorted=true)
    end
    open("$data/download_families.toml", "w") do io
        println(io, header)
        TOML.print(io, support; sorted=true)
    end
    @info "exported source mappings" mode downloads=length(downloads) repositories=length(repositories) ambiguous=result.ambiguous

    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS...)
end
