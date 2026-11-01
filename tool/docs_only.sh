#!/usr/bin/env bash
# Is a change documentation only? Exits 0 when every file that differs between
# BASE and HEAD is Markdown the test suite never reads, and 1 otherwise —
# including when the range can't be read, so a mistake costs a test run rather
# than skipping one.
#
#   bash tool/docs_only.sh BASE [HEAD]
#
# The one definition of "docs-only" in the repo. The pre-push coverage gate
# (tool/push_gate.sh) and the PR checks (.github/workflows/docs-only.yml) both
# ask this script, so a push and its PR can never disagree about skipping.
#
# A file counts as documentation when it ends in .md or .markdown and lives
# outside the trees the app and its tests read Markdown from:
#   assets/  the built-in tutorial engram, shipped in the app
#   test/    fixtures, including the manual-testing engram
#   lib/     sources, and anything they may load
# Everything else — Dart, YAML, ARB, scripts, the markdownlint config — runs
# the full suite.
#
# The comparison is BASE...HEAD (from their merge base), with renames split
# into a delete and an add, so moving lib/notes.md to docs/notes.md still
# counts the deletion under lib/. Deleted files are listed too; pre-commit's
# own file filter drops those, which is why the hook doesn't rely on it.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: bash tool/docs_only.sh BASE [HEAD]" >&2
  exit 2
fi
base=$1
head=${2:-HEAD}

if ! changed=$(git diff --name-only --no-renames "$base...$head" 2>/dev/null); then
  echo "docs_only: cannot diff $base...$head; treating as not docs-only" >&2
  exit 1
fi

# An empty range has nothing to judge; run the suite rather than guess.
[[ -n $changed ]] || exit 1

while IFS= read -r file; do
  case $file in
    assets/* | test/* | lib/*) exit 1 ;;
    *.md | *.markdown) ;;
    *) exit 1 ;;
  esac
done <<<"$changed"
exit 0
