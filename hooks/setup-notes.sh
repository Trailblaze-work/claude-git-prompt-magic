#!/usr/bin/env bash
set -euo pipefail

# SessionStart hook: idempotently configures git to display and fetch
# Claude Code prompt notes (refs/notes/claude-prompts).
#
# Notes are pushed by capture-prompts.sh immediately after creation,
# NOT via remote.origin.push (which would override default push behavior
# and break `git push` when no notes exist yet).

# Show claude-prompts notes inline in git log
git config --local notes.displayRef "refs/notes/claude-prompts"

# Fetch notes from remote and clean up push refspec (only if origin exists)
if git remote get-url origin >/dev/null 2>&1; then
    FETCH_REF="+refs/notes/claude-prompts:refs/notes/claude-prompts"
    if ! git config --local --get-all remote.origin.fetch 2>/dev/null | grep -qF "$FETCH_REF"; then
        git config --add --local remote.origin.fetch "$FETCH_REF"
    fi

    # Clean up any leftover push refspec from earlier versions
    if git config --local --get-all remote.origin.push 2>/dev/null | grep -qF "refs/notes/claude-prompts"; then
        git config --unset-all --local remote.origin.push "refs/notes/claude-prompts" 2>/dev/null || true
    fi
fi

exit 0
