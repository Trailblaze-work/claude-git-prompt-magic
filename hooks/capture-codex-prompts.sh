#!/usr/bin/env bash
set -euo pipefail

# post-commit hook helper for Codex:
# 1) Read CODEX_THREAD_ID from environment.
# 2) Extract user prompts for this commit from ~/.codex/sessions.
# 3) Attach prompts as git notes in refs/notes/claude-prompts.

THREAD_ID="${CODEX_THREAD_ID:-}"
if [[ -z "$THREAD_ID" ]]; then
    exit 0
fi

COMMIT_HASH="$(git rev-parse --verify HEAD 2>/dev/null || true)"
if [[ -z "$COMMIT_HASH" ]]; then
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTRACTOR="$SCRIPT_DIR/codex_prompt_extractor.py"
if [[ ! -f "$EXTRACTOR" ]]; then
    exit 0
fi

NOTE="$(
    python3 "$EXTRACTOR" \
        --thread-id "$THREAD_ID" \
        --commit-hash "$COMMIT_HASH" \
        2>/dev/null || true
)"

if [[ -z "${NOTE//[[:space:]]/}" ]]; then
    exit 0
fi

if ! git notes --ref=claude-prompts add -f -m "$NOTE" "$COMMIT_HASH" >/dev/null 2>&1; then
    exit 0
fi

git push origin refs/notes/claude-prompts >/dev/null 2>&1 || true
