using TOML: TOML
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
    pkgs = (link_type=Int8[], link_id=Int32[], repo=String[], effname=String[], rawversion=String[],
        arch=Union{String,Missing}[], origversion=String[])
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
    return df, pkg_cpes, manual_cpes
end

function gather_links(df)
    # We'll only trust download URLs when only one was used for the given package
    # Many packages have more than one download, but then we don't know if that was a (build) dependency
    # or the actual project or perhaps some larger meta-project that vendors lots of deps.
    filtered_df = df |>
        x -> groupby(x, [:repo, :effname, :rawversion, :arch]) |>
        x -> transform(x, :url => (x -> length(unique(x))) => :n_unique_urls) |>
        x -> filter(row -> row.n_unique_urls == 1, x) |>
        # And also remove any rows for which the same URL points at two different effnames:
        x -> groupby(x, :url) |>
        x -> transform(x, :effname => (x -> length(unique(x))) => :n_unique_effnames) |>
        x -> filter(row -> row.n_unique_effnames == 1, x)

    # For repositories (link_type == 2), ignore versions
    repositories = Dict{String,String}()
    for row in eachrow(filtered_df[filtered_df.link_type .== 2, :])
        if haskey(repositories, row.url) && repositories[row.url] != row.effname
            @warn "$(row.url) identifies both $(row.effname) and $(repositories[row.url])"
            repositories[row.url] = "" # poison repos that are used for more than one project
            continue
        end
        repositories[row.url] = row.effname
    end
    filter!(!isempty∘last, repositories)

    @info "gather downloads"
    # For downloads (link_type == 1), the versions may be meaningfully linked to the URL
    url_groups = combine(groupby(filtered_df[filtered_df.link_type .== 1, :], [:url, :effname]), :origversion => (x -> [unique(x)]) => :versions)
    downloads = Dict{String, Pair{String,String}}()
    for row in eachrow(url_groups)
        length(row.versions) == 1 || continue
        # Ignore download URLs that don't explicitly include the URL
        # these are often things like -latest or the like
        v = only(row.versions)
        contains(row.url, v) || continue
        if haskey(downloads, row.url) && downloads[row.url] != (row.effname => v)
            @warn "$(row.url) identifies both $(row.effname => v) and $(downloads[row.url])"
            downloads[row.url] = "" => ""
            continue
        end
        downloads[row.url] = (row.effname => v)
    end
    filter!(!isempty∘last∘last, downloads)

    return downloads, repositories
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

function main(dump=DUMP_URL)
    @info "reading $dump"
    df, pkg_cpes, manual_cpes = open(pipeline(isfile(dump) ? `cat $dump` : `curl -sSfL $dump`, `zstd -dc`)) do io
        read_dump(io)
    end
    @info "read $(nrow(df)) package links"
    downloads, repositories = gather_links(df)
    cpes = gather_cpes(pkg_cpes, manual_cpes)

    data = joinpath(@__DIR__, "..", "data")
    mkpath(data)

    # Each dump only has the packages that distributions currently ship, so download URLs for older releases (and
    # repositories that are ambiguous this week) drop out of it. Keep previously-exported entries unless the new
    # dump says otherwise.
    existing(file) = isfile("$data/$file") ? TOML.parsefile("$data/$file") : Dict{String,Any}()
    downloads = merge(Dict(k => (v[1] => v[2]) for (k,v) in existing("downloads.toml")), downloads)
    repositories = merge(Dict{String,String}(existing("repositories.toml")), repositories)
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
