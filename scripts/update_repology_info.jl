using TOML: TOML
using Repology: Repology
using DataStructures: DefaultDict, DefaultOrderedDict, OrderedDict
using DataFrames: DataFrames, DataFrame, groupby, transform, eachrow, nrow, select!, Not

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
    pkgs = (link_type=Int8[], link_id=Int32[], repo=String[], effname=String[], rawversion=String[],
        arch=Union{String,Missing}[], origversion=String[])
    pkg_cpes = Set{Tuple{String,String}}()
    manual_cpes = Tuple{String,String}[]
    intern = Dict{String,String}()
    project_families = Dict{String,Set{String}}()
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
            family = get!(intern, f[cols["family"]], f[cols["family"]])
            push!(get!(Set{String}, project_families, effname), family)
            vendor, product = copy_value(f[cols["cpe_vendor"]]), copy_value(f[cols["cpe_product"]])
            !ismissing(vendor) && !ismissing(product) && push!(pkg_cpes, (effname, "$vendor:$product"))
            repo = get!(intern, f[cols["repo"]], f[cols["repo"]])
            arch = copy_value(f[cols["arch"]])
            arch = ismissing(arch) ? missing : get!(intern, arch, arch)
            rawversion, origversion = copy_value(f[cols["rawversion"]]), copy_value(f[cols["origversion"]])
            for m in eachmatch(r"\[(\d+), (\d+)", f[cols["links"]])
                t = parse(Int8, m.captures[1])
                t in (1, 2) || continue
                push!(pkgs.link_type, t); push!(pkgs.link_id, parse(Int32, m.captures[2]))
                push!(pkgs.repo, repo); push!(pkgs.effname, effname); push!(pkgs.rawversion, rawversion)
                push!(pkgs.arch, arch); push!(pkgs.origversion, origversion)
            end
        elseif table == "manual_cpes"
            vendor, product = copy_value(f[cols["cpe_vendor"]]), copy_value(f[cols["cpe_product"]])
            !ismissing(vendor) && !ismissing(product) && push!(manual_cpes, (String(f[cols["effname"]]), "$vendor:$product"))
        end
    end
    df = DataFrame(pkgs)
    df.url = [links[id] for id in df.link_id]
    select!(df, Not(:link_id))
    return df, pkg_cpes, manual_cpes, Dict(p => length(fs) for (p, fs) in project_families)
end

function gather_links(df, family_counts; minimum_margin=2, maximum_urls=3)
    minimum_margin >= 1 || throw(ArgumentError("minimum_margin must be positive"))
    maximum_urls >= 1 || throw(ArgumentError("maximum_urls must be positive"))
    # Uncontested URLs still require a single source URL per package.
    counted_df = df |>
        x -> groupby(x, [:repo, :effname, :rawversion, :arch]) |>
        x -> transform(x, :url => (x -> length(unique(x))) => :n_unique_urls)
    counted_df.normalized_url = Repology.normalize_url.(counted_df.url)
    repositories = Dict{String,String}()
    downloads = Dict{String, Pair{String,String}}()
    resolved = Dict{String,String}()
    for group in groupby(counted_df, :normalized_url)
        contested = length(unique(group.effname)) > 1
        eligible = filter(row -> row.n_unique_urls <= maximum_urls, group)
        isempty(eligible) && continue
        projects = unique(eligible.effname)
        sort!(projects; by=p -> (-family_counts[p], p))
        length(projects) > 1 && family_counts[projects[1]] - family_counts[projects[2]] < minimum_margin && continue
        project = first(projects)
        rows = filter(row -> row.effname == project && (contested || row.n_unique_urls == 1), eligible)
        isempty(rows) && continue
        normalized = first(group.normalized_url)
        resolved[normalized] = project
        aliases = unique(group.url)
        if any(==(2), rows.link_type)
            for url in aliases
                repositories[url] = project
            end
        end
        versions = unique(rows.origversion[rows.link_type .== 1])
        length(versions) == 1 || continue
        v = only(versions)
        isempty(v) && continue
        for url in aliases
            contains(url, v) && (downloads[url] = project => v)
        end
    end
    return downloads, repositories, resolved
end

function retarget_history(old, resolved; downloads=false)
    return Dict(url => (downloads ? get(resolved, Repology.normalize_url(url), first(value)) => last(value) :
        get(resolved, Repology.normalize_url(url), value)) for (url, value) in old)
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
    df, pkg_cpes, manual_cpes, family_counts = open(pipeline(isfile(dump) ? `cat $dump` : `curl -sSfL $dump`, `zstd -dc`)) do io
        read_dump(io)
    end
    @info "read $(nrow(df)) package links"
    downloads, repositories, resolved = gather_links(df, family_counts)
    cpes = gather_cpes(pkg_cpes, manual_cpes)

    data = ENV["REPOLOGY_DATA_OUT"]
    mkpath(data)

    # Each dump only has the packages that distributions currently ship, so download URLs for older releases (and
    # repositories that are ambiguous this week) drop out of it. Keep previously-exported entries (from the current
    # data artifact) unless the new dump says otherwise.
    existing(file) = TOML.parsefile(joinpath(Repology.data_dir(), file))
    old_downloads = Dict(k => (v[1] => v[2]) for (k,v) in existing("downloads.toml"))
    old_repositories = Dict{String,String}(existing("repositories.toml"))
    downloads = merge(retarget_history(old_downloads, resolved; downloads=true), downloads)
    repositories = merge(retarget_history(old_repositories, resolved), repositories)
    write_project_changes(get(ENV, "REPOLOGY_PROJECT_CHANGES", ""),
        [(url, first(old_downloads[url]), first(p)) for (url, p) in downloads if haskey(old_downloads, url)],
        [(url, old_repositories[url], p) for (url, p) in repositories if haskey(old_repositories, url)])
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

    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS...)
end
