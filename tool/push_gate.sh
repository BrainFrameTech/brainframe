#!/usr/bin/env bash
# The pre-push coverage gate: runs tool/coverage.sh, unless everything being
# pushed is documentation the test suite never reads (tool/docs_only.sh says
# which). Wired in .pre-commit-config.yaml as the `coverage-gate` hook.
#
# pre-commit exports the range being pushed as PRE_COMMIT_FROM_REF and
# PRE_COMMIT_TO_REF. When they are missing — `pre-commit run` by hand, or a
# push pre-commit can't compute a range for — the suite runs, as it always did.
set -euo pipefail

from=${PRE_COMMIT_FROM_REF:-}
to=${PRE_COMMIT_TO_REF:-}
if [[ -n $from && -n $to ]] && bash tool/docs_only.sh "$from" "$to"; then
  echo "Documentation-only push: skipping the test suite (tool/docs_only.sh)."
  exit 0
fi
exec bash tool/coverage.sh "$@"
