# Repology

An interface to access data from https://repology.org

## Data

The data exported from Repology's database dump (`repositories.toml`, `downloads.toml` and `cpes.toml`) is the
`repology_data` [artifact](https://pkgdocs.julialang.org/v1/artifacts/), not part of this repository. Each version
is an asset of the [`repology-data` release](../../releases/tag/repology-data), named by its sha256 and bound in
`Artifacts.toml`. `Repology.data_dir()` gives its location; set `REPOLOGY_DATA` to use another directory.

The weekly "Export from Repology's DB dump" workflow writes a refresh with `scripts/update_repology_info.jl`, checks
it against the test corpus, uploads it with `scripts/publish_data.jl`, and then pushes the `Artifacts.toml` change or
opens a PR for review. Never delete or replace release assets: older versions of the package still point at them.

Hand-curated data (`additional_info.toml`, `test/corpus.toml`) stays in this repository.
