# Repology

An interface to access data from https://repology.org

## Data

The data exported from Repology's database dump (`repositories.toml`, `downloads.toml` and `cpes.toml`) is the
`repology_data` [artifact](https://pkgdocs.julialang.org/v1/artifacts/). Each version
is its own [release](../../releases) tagged `data-YYYY-MM-DD` (plus the workflow run id for a second refresh that day), with the tarball named by its sha256 and bound in
`Artifacts.toml`. `Repology.data_dir()` gives its location; set `REPOLOGY_DATA` to use another directory.

The weekly "Export from Repology's DB dump" workflow writes a refresh with `scripts/update_repology_info.jl`, checks
it against the test corpus, uploads it with `scripts/publish_data.jl`, and then pushes the `Artifacts.toml` change or
opens a PR for review. Never delete or replace a data release that any version of the package still points at.

Until the first artifact is published, `Repology.data_dir()` falls back to the `data` directory committed here.
