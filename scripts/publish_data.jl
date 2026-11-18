# Package a refreshed data directory as the `repology_data` artifact and bind it in Artifacts.toml.
#   julia --project=. scripts/publish_data.jl DATA_DIR TARBALL_DIR DOWNLOAD_URL_PREFIX
# Writes the tarball to TARBALL_DIR/repology_data-<sha256>.tar.gz, which must then be uploaded to
# DOWNLOAD_URL_PREFIX. Does nothing if the data didn't change. Prints the tarball path, or nothing.
using Pkg.Artifacts: create_artifact, artifact_hash, archive_artifact, bind_artifact!
using SHA: sha256

function main(data, tarballs, url_prefix)
    artifacts_toml = joinpath(@__DIR__, "..", "Artifacts.toml")
    hash = create_artifact(dir -> foreach(f -> cp(joinpath(data, f), joinpath(dir, f)), readdir(data)))
    hash == artifact_hash("repology_data", artifacts_toml) && return
    # Archives of the same data aren't byte-identical (gzip timestamps), so name each by its own sha256
    tmp = joinpath(mkpath(tarballs), "repology_data.tar.gz")
    archive_artifact(hash, tmp)
    sha = bytes2hex(open(sha256, tmp))
    tarball = joinpath(tarballs, "repology_data-$sha.tar.gz")
    mv(tmp, tarball; force=true)
    bind_artifact!(artifacts_toml, "repology_data", hash; force=true,
        download_info=[(string(rstrip(url_prefix, '/'), "/", basename(tarball)), sha)])
    print(tarball)
end

main(ARGS...)
