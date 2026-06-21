#!/usr/bin/env bash
# Applicable in repos that call an LLM SDK (prompt templates live alongside the client).
cd "$1" || exit 1
grep -qiE '(openai|anthropic|google-generativeai|google-genai|mistralai|cohere|litellm)' \
  pyproject.toml requirements*.txt Pipfile 2>/dev/null && exit 0
exit 1
