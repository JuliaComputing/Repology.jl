#!/bin/bash
# Until the first repology_data artifact is published, extract the data last committed to git into DIR and print
# DIR, so that the first refresh keeps previously-exported entries and the tests have data. Prints nothing (and
# does nothing) once Artifacts.toml binds repology_data. Needs the full git history.
set -euo pipefail
dir=$1
grep -qs '^\[repology_data\]' "$(dirname "$0")/../Artifacts.toml" && exit 0
last=$(git rev-list -1 HEAD -- data/repositories.toml)
mkdir -p "$dir"
for f in repositories downloads cpes; do
  git show "$last^:data/$f.toml" > "$dir/$f.toml"
done
echo "$dir"
