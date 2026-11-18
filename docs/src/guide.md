# Guide

## Identification and provenance

[`Repology.identify`](@ref) returns an [`Repology.Identification`](@ref) with
`project`, `version`, and `provenance` fields. Either project or version can be
`nothing`; an unknown URL returns all three fields as `nothing`. The result can
also be destructured into `(project, version)` (provenance is not iterated).

```julia
id = Repology.identify("https://github.com/owner/repo.git"; commit="0123456789abcdef")
project, version = id
```

Only 7–40 character lowercase hexadecimal commit identifiers are used. Commit
identification can list remote tags and clone a repository, falling back to tags
on the first parent. Network failures in tag lookup yield no tags rather than a
version. A known repository can still produce a project without a version.

[`Repology.PROVENANCES`](@ref) lists the identification strategies: hand-verified
source overrides, curated URL patterns, exact/normalized download matches,
forge URL tag parsing, commit tag lookup, repository matching, and inferred
download-URL shapes. The provenance describes the version's source when a version
is found, otherwise the project's source. In the known-repository path, a
compatible heuristic version is preferred over a project-only repository result.
Versions must pass [`Repology.is_plausible_version`](@ref); identification is not
proof that the source is authentic or that a version exists upstream.

`use_overrides=false` disables only the hand-verified `sources` overrides, not
the other curated metadata. [`Repology.identify_upstream`](@ref) is the older
two-value wrapper without provenance.

## Version comparison

[`Repology.vercmp`](@ref) compares strings using libversion. With a project name,
it uses [`Repology.version_scheme`](@ref), and may return `nothing` when ambiguous
version features are not supported by the project's known releases. Curated
schemes are trusted; SemVer schemes reject strings that cannot be parsed as
Julia `VersionNumber`s and ignore build metadata for precedence.

## Curating additional_info.toml

`additional_info.toml` contains tables keyed by Repology project name. All fields
are optional; consult the existing entries before adding one.

* `sources`: hand-verified tables with `url`, optional `commit`, and optional
  `version`. They match the exact URL and commit pair and take precedence over
  other strategies. Omitting `version` deliberately identifies only the project.
* `url_patterns`: regular expressions matching source URLs; the first capture
  group supplies the version. No capture (or an implausible version) gives a
  project-only result. Patterns take precedence over the exported URL data.
* `repositories`: repository URLs, preferred over Repology's repository mapping.
* `tag_patterns`: tables with `regex` and optional `version` substitution string
  (default `"\\1"`). These parse versions and distinguish projects sharing a
  repository. TOML strings must escape backslashes, as in the example below.
* `cpes`: CPE prefixes for consumers of the curation file. `Repology.cpe_data()`
  reads the exported artifact's CPE data; it does not merge this field itself.
* `version_scheme`: `"libversion"` or `"semver"`.
* `version_flags`: libversion flag names `"P_IS_PATCH"` and/or `"ANY_IS_PATCH"`.

```toml
[example]
repositories = ["https://github.com/owner/example.git"]
tag_patterns = [{regex = "^release-(.*)$", version = "\\1"}]
sources = [{url = "https://example.org/source.tar.gz", version = "1.2.3"}]
```

Metadata and data maps are cached in process. Restart Julia after changing them.
Add regression cases in `test/runtests.jl` or `test/corpus.toml`, then run
`julia --project=. -e 'using Pkg; Pkg.test()'`. Review known corpus failures in
`test/known_failures.toml` rather than silently accepting regressions.

## Data artifact and refreshes

[`Repology.data_dir`](@ref) locates the `repology_data` artifact bound in
`Artifacts.toml`. It contains `repositories.toml`, `downloads.toml`, and
`cpes.toml`. A nonempty `REPOLOGY_DATA` environment variable overrides the
directory (set it before data is first loaded). Package instantiation installs
the bound artifact; `data_dir()` itself only resolves its location.

The **Export from Repology's DB dump** workflow runs weekly or manually. It streams
the compressed SQL dump through `zstd`, extracts relevant links and CPEs, and
keeps previously exported entries unless the new dump replaces them. It does not
restore a PostgreSQL database. A local refresh can be tested with:

```sh
export JULIA_PKG_USE_CLI_GIT=true
julia --project=. -e 'using Pkg; Pkg.instantiate()'
REPOLOGY_DATA_OUT="$PWD/data" julia --project=. scripts/update_repology_info.jl
REPOLOGY_DATA="$PWD/data" julia --project=. -e 'using Pkg; Pkg.test()'
```

The exporter requires `curl` and `zstd`; an optional positional argument selects
a local compressed dump instead of downloading the latest one. Do not set
`REPOLOGY_DATA` to the output directory while exporting: the exporter reads the
existing data to preserve older entries. `REPOLOGY_PROJECT_CHANGES` optionally
names a Markdown report of URLs whose project changed.

`scripts/publish_data.jl DATA_DIR TARBALL_DIR DOWNLOAD_URL_PREFIX` packages changed
data, prints the tarball path, and updates `Artifacts.toml`; it does not upload
the archive. The workflow uploads to a `data-YYYY-MM-DD` release (with a workflow
run id suffix for another refresh that day). It tests the corpus, records known
failures, and pushes a clean refresh directly, or proposes a PR when corpus
regressions or changed project mappings need review. Never delete or replace a
data release referenced by any package version.
