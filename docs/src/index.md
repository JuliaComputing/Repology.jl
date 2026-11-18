# Repology.jl

Repology.jl identifies upstream projects and versions from source URLs using
[Repology](https://repology.org) data and hand-curated metadata. It can also compare
upstream version strings using Repology's libversion comparator or a project's
curated version scheme.

The package reads a versioned data artifact, not a live Repology API. Identifying
a repository commit may contact the upstream Git server.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/mbauman/Repology.jl")
```

## Quick start

```@example quickstart
using Repology
id = Repology.identify("https://github.com/libexpat/libexpat/releases/download/R_2_8_3/expat-2.8.3.tar.xz")
(id.project, id.version, id.provenance)
```

Use qualified names such as `Repology.identify`: the module currently exports no
names. See the [Guide](@ref) for identification, curation, and data refreshes, and
the [API reference](@ref) for docstrings.
