#!/usr/bin/env bash
# Applicable when the repo uses semantic-release on main — the GitHub Flow model
# from backend-repo-bootstrap / ios-app-bootstrap: a .releaserc is present.
cd "$1" || exit 1
[ -f .releaserc ] || exit 1
exit 0
