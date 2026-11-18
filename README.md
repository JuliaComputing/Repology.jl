# Repology.jl

[![Documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://mbauman.github.io/Repology.jl/dev/)
[![CI](https://github.com/mbauman/Repology.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/mbauman/Repology.jl/actions/workflows/CI.yml)

Identify upstream projects and versions from source URLs using
[Repology](https://repology.org) data and curated metadata. Results include
provenance; version comparison supports libversion and project-specific schemes.
The package uses a versioned data snapshot, not a live Repology API.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/mbauman/Repology.jl")
```

## Usage

```julia
using Repology
id = Repology.identify("https://github.com/libexpat/libexpat/releases/download/R_2_8_3/expat-2.8.3.tar.xz")
(id.project, id.version, id.provenance)
# ("expat", "2.8.3", "url-pattern")
```

Names are qualified (the module exports none). An unknown URL returns an
identification with `nothing` fields; a known project can lack a version. Pass
`commit=` for repository sources; tag lookup may access the network and clone
the repository. See the [guide and API reference](https://mbauman.github.io/Repology.jl/dev/).

## Curation and data refresh

`additional_info.toml` supplies per-project URL patterns, repositories, tag
patterns, hand-verified sources, CPE prefixes, and version schemes. Add regression
tests with curation changes and run `julia --project=. -e 'using Pkg; Pkg.test()'`.
Metadata is cached, so restart Julia after edits.

`repositories.toml`, `downloads.toml`, and `cpes.toml` live in the `repology_data`
artifact bound by `Artifacts.toml`. `Repology.data_dir()` resolves its directory;
set `REPOLOGY_DATA` before loading data to test an alternate snapshot.

The weekly/manual **Export from Repology's DB dump** workflow extracts a refresh
with `scripts/update_repology_info.jl`, retaining older entries absent from the
new dump. It tests the corpus and packages/uploads changed data with
`scripts/publish_data.jl` into immutable `data-YYYY-MM-DD` releases (plus a run id
for repeat refreshes). Clean refreshes push the artifact binding; regressions or
changed project mappings produce a review PR. Never delete or replace a data
release referenced by any package version. The
[guide](https://mbauman.github.io/Repology.jl/dev/guide/) covers local refreshes and curation.
