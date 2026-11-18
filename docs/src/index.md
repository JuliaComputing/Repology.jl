# Repology.jl

Repology.jl connects arbitrary source URLs, like the tarballs and git commits
that build recipes download, to canonically-named upstream projects and versions
from [Repology](https://repology.org). With a canonical project name, a source can
be matched against security advisories (via CPEs), compared against the latest
upstream release, and related to what other distributions ship.

It combines a snapshot of Repology's data with hand-curated metadata, and records
the provenance of each answer. See the [Guide](@ref) for the motivation and details.

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
