# Whether identification `id` agrees with corpus entry `e`. "jll-version" entries assume the JLL's version is the
# upstream one, but JLL versions can't carry suffixes like xorriso's `1.5.6.pl02`; accept such a longer version when the
# source URL spells it out.
function corpus_match(e, id)
    isnothing(id.version) && return false
    e["kind"] == "manual" && return id.project == e["project"] && id.version == e["version"]
    id.version == e["version"] && return true
    rest = chopprefix(id.version, e["version"])
    return rest != id.version && !isdigit(first(rest)) && occursin(id.version, e["url"])
end
