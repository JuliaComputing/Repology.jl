# Guide

## Why Repology.jl?

Build recipes (like Julia's JLLs from Yggdrasil) download source code from
arbitrary URLs: release tarballs on project websites, mirrors, GitHub archives,
or a git repository at some commit. Nothing in those URLs says *which* upstream
project they are, or what release. Asking "is this JLL affected by CVE-XXXX?" or
"how far behind upstream is this package?" first requires answering that
question for every source.

[Repology](https://repology.org) already tracks thousands of projects across
hundreds of package repositories under a single canonical name per project
(`expat`, `openssl`, `libpng`, …), along with the download URLs, repositories,
and CPEs that distributions use for them. Repology.jl uses that data to connect
an arbitrary source URL (and optional commit) to a canonically-named Repology
project and an upstream version:

```julia
julia> Repology.identify("https://github.com/libexpat/libexpat/releases/download/R_2_8_3/expat-2.8.3.tar.xz")
Repology.Identification("expat", "2.8.3", "url-pattern")
```

Once a source has a Repology project name, everything else Repology knows about
that project (its versions, its CPE for matching security advisories, what other
distributions ship) becomes reachable. Repology's data alone isn't enough to do
this reliably, so the package layers hand-curated metadata on top
(`additional_info.toml`) and records *how* each answer was found
(its `provenance`), so downstream consumers can decide how much to trust it.

The rest of this guide covers how identification works, how to curate it when it
gets something wrong, and how the underlying data is refreshed.

## How identification works

[`Repology.identify`](@ref) takes a URL (and, for git sources, a `commit`) and
tries a series of strategies, from most to least trustworthy. The first one that
succeeds determines the result's `provenance` (see [`Repology.PROVENANCES`](@ref)):

1. `"override"`: the URL (and commit) is a hand-verified source in `additional_info.toml`.
2. `"url-pattern"`: the URL matches a curated regular expression for a project.
3. `"repology-url"`: the URL (exactly, or after normalization) is a download URL
   that some distribution has packaged for this project.
4. `"tag-scheme"`: the URL is a GitHub/GitLab release or tag archive of a known
   repository, and the tag parses as a version.
5. `"git-tag"`: the URL is a known repository and the commit is tagged (or its
   first parent is). This may list remote tags and clone the repository.
6. `"repository"`: the repository is known, but no version could be found.
7. `"heuristic"`: the URL has the same shape as a known download URL, with a
   different version number in it.

```julia
julia> Repology.identify("https://github.com/madler/zlib.git"; commit="51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf")
Repology.Identification("zlib", "1.3.1", "git-tag")
```

The result is an [`Repology.Identification`](@ref). Either `project` or `version`
may be `nothing`: an unknown URL gives all `nothing`s, and a known project can lack
a version. It destructures as `project, version = id`. Every version must pass
[`Repology.is_plausible_version`](@ref) (it looks like a version and fits the
versions Repology knows for that project), but an identification is evidence,
not proof that upstream released that version.

`use_overrides=false` skips the hand-verified `sources` (useful for checking that
the automatic strategies agree with them). [`Repology.identify_upstream`](@ref)
is the older two-value wrapper without provenance.

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
