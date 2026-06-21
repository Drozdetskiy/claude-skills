#!/usr/bin/env bash
# Applicable in repos that call an LLM SDK: a Python dependency manifest names one of
# the major LLM client libraries.
cd "$1" || exit 1
grep -qiE '(openai|anthropic|google-generativeai|google-genai|mistralai|cohere|litellm)' \
  pyproject.toml requirements*.txt Pipfile 2>/dev/null && exit 0
exit 1
