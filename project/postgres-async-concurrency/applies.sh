#!/usr/bin/env bash
# Applicable in repos using SQLAlchemy over asyncpg (async Postgres) — both must appear
# in a Python dependency manifest.
cd "$1" || exit 1
manifests=(pyproject.toml requirements*.txt Pipfile)
grep -qiE 'sqlalchemy' "${manifests[@]}" 2>/dev/null || exit 1
grep -qiE 'asyncpg'    "${manifests[@]}" 2>/dev/null || exit 1
exit 0
