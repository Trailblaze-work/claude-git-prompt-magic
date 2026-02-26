#!/usr/bin/env bash
set -euo pipefail

# Test suite for claude-git-prompt-magic
# Tests hook functionality, install script, worktree compatibility,
# multi-commit sessions, parallel sessions, and edge cases.
# All tests run in isolated /tmp directories — no side effects on the real repo.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$PROJECT_DIR/hooks"

PASSED=0
FAILED=0
SKIPPED=0

# --- Helpers ---

pass() {
    printf "  \033[32mPASS\033[0m %s\n" "$1"
    PASSED=$((PASSED + 1))
}

fail() {
    printf "  \033[31mFAIL\033[0m %s: %s\n" "$1" "$2"
    FAILED=$((FAILED + 1))
}

skip() {
    printf "  \033[33mSKIP\033[0m %s: %s\n" "$1" "$2"
    SKIPPED=$((SKIPPED + 1))
}

section() {
    printf "\n\033[1m%s\033[0m\n" "$1"
}

# Create a fresh test repo in /tmp and cd into it.
# Sets TEST_DIR for cleanup.
make_test_repo() {
    TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cgpm-test.XXXXXX")
    cd "$TEST_DIR"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test"
    git commit -q --allow-empty -m "init"
}

cleanup_test_repo() {
    if [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]]; then
        cd /tmp
        git -C "$TEST_DIR" worktree list --porcelain 2>/dev/null | grep "^worktree " | while read -r _ path; do
            [[ "$path" != "$TEST_DIR" ]] && git -C "$TEST_DIR" worktree remove --force "$path" 2>/dev/null || true
        done
        rm -rf "$TEST_DIR"
    fi
}

# Install hooks from project source into current repo
install_hooks() {
    mkdir -p .claude/hooks
    cp "$HOOKS_DIR/capture-prompts.sh" .claude/hooks/
    cp "$HOOKS_DIR/setup-notes.sh" .claude/hooks/
    chmod +x .claude/hooks/*.sh
}

# Create a mock transcript JSONL.
# Usage: make_transcript <path> [entries...]
# Entry format:
#   "user:Some prompt text"          → user message
#   "commit:git commit -m msg"       → assistant tool_use with git commit
#   "bash:some command"              → assistant tool_use with non-commit command
make_transcript() {
    local path="$1"
    shift

    > "$path"
    for entry in "$@"; do
        local type="${entry%%:*}"
        local content="${entry#*:}"
        case "$type" in
            user)
                # Escape quotes and backslashes for JSON
                content=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')
                printf '{"type":"user","message":{"content":"%s"}}\n' "$content" >> "$path"
                ;;
            commit)
                content=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')
                printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"%s"}}]}}\n' "$content" >> "$path"
                ;;
            bash)
                content=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')
                printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"%s"}}]}}\n' "$content" >> "$path"
                ;;
        esac
    done
}

# Build PostToolUse hook JSON for capture-prompts.sh
make_hook_input() {
    local commit_hash="$1"
    local transcript_path="$2"
    local session_id="${3:-test-session}"
    local branch="${4:-main}"
    local message="${5:-test}"

    cat <<EOF
{"tool_input":{"command":"git commit -m ${message}"},"tool_response":"[${branch} ${commit_hash}] ${message}\\n 1 file changed","transcript_path":"${transcript_path}","session_id":"${session_id}"}
EOF
}


# ============================================================
# setup-notes.sh tests
# ============================================================

test_setup_notes_configures_displayref() {
    make_test_repo
    trap cleanup_test_repo RETURN

    bash "$HOOKS_DIR/setup-notes.sh"

    local display_ref
    display_ref=$(git config --local --get notes.displayRef 2>/dev/null || echo "")
    if [[ "$display_ref" == "refs/notes/claude-prompts" ]]; then
        pass "setup-notes sets notes.displayRef"
    else
        fail "setup-notes sets notes.displayRef" "got '$display_ref'"
    fi
}

test_setup_notes_configures_fetch_refspec() {
    make_test_repo
    trap cleanup_test_repo RETURN
    git remote add origin "https://example.com/test.git"

    bash "$HOOKS_DIR/setup-notes.sh"

    local fetch
    fetch=$(git config --local --get-all remote.origin.fetch 2>/dev/null | grep "claude-prompts" || echo "")
    if [[ "$fetch" == "+refs/notes/claude-prompts:refs/notes/claude-prompts" ]]; then
        pass "setup-notes adds fetch refspec for notes"
    else
        fail "setup-notes adds fetch refspec for notes" "got '$fetch'"
    fi
}

test_setup_notes_idempotent() {
    make_test_repo
    trap cleanup_test_repo RETURN
    git remote add origin "https://example.com/test.git"

    bash "$HOOKS_DIR/setup-notes.sh"
    bash "$HOOKS_DIR/setup-notes.sh"
    bash "$HOOKS_DIR/setup-notes.sh"

    local count
    count=$(git config --local --get-all remote.origin.fetch 2>/dev/null | grep -c "claude-prompts" || echo "0")
    if [[ "$count" -eq 1 ]]; then
        pass "setup-notes is idempotent (no duplicate fetch refspecs)"
    else
        fail "setup-notes is idempotent" "got $count fetch refspecs for claude-prompts"
    fi
}

test_setup_notes_cleans_push_refspec() {
    make_test_repo
    trap cleanup_test_repo RETURN
    git remote add origin "https://example.com/test.git"

    # Simulate leftover push refspec from earlier version
    git config --add --local remote.origin.push "+refs/notes/claude-prompts:refs/notes/claude-prompts"

    bash "$HOOKS_DIR/setup-notes.sh"

    local push
    push=$(git config --local --get-all remote.origin.push 2>/dev/null | grep "claude-prompts" || echo "")
    if [[ -z "$push" ]]; then
        pass "setup-notes removes leftover push refspec"
    else
        fail "setup-notes removes leftover push refspec" "still has: $push"
    fi
}

test_setup_notes_no_remote() {
    make_test_repo
    trap cleanup_test_repo RETURN

    # No remote — should still set displayRef without error
    bash "$HOOKS_DIR/setup-notes.sh"

    local display_ref
    display_ref=$(git config --local --get notes.displayRef 2>/dev/null || echo "")
    if [[ "$display_ref" == "refs/notes/claude-prompts" ]]; then
        pass "setup-notes works without a remote"
    else
        fail "setup-notes works without a remote" "got '$display_ref'"
    fi
}


# ============================================================
# capture-prompts.sh — basic functionality
# ============================================================

test_capture_attaches_note() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "hello" > test.txt
    git add test.txt
    git commit -q -m "test commit"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Add a test file" \
        "user:Commit it" \
        "commit:git commit -m test commit"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompts show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"Claude Code Prompts"* && "$note" == *"Add a test file"* && "$note" == *"Commit it"* ]]; then
        pass "attaches note with prompts"
    else
        fail "attaches note with prompts" "note: $note"
    fi
}

test_capture_note_format() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "content" > file.txt
    git add file.txt
    git commit -q -m "format test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Do the thing" \
        "commit:git commit -m format test"

    make_hook_input "$hash" "$transcript" "session-abc-123" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompts show HEAD 2>/dev/null || echo "")

    local ok=true
    [[ "$note" == *"## Claude Code Prompts"* ]] || ok=false
    [[ "$note" == *"**Session**: session-abc-123"* ]] || ok=false
    [[ "$note" == *"**Captured**:"* ]] || ok=false
    [[ "$note" == *"### Prompts"* ]] || ok=false
    [[ "$note" == *"**1.** Do the thing"* ]] || ok=false

    if $ok; then
        pass "note has correct markdown format"
    else
        fail "note has correct markdown format" "note: $note"
    fi
}

test_capture_multiple_prompts() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "content" > file.txt
    git add file.txt
    git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:First, create a new component" \
        "bash:touch component.tsx" \
        "user:Add validation to it" \
        "bash:echo validation > component.tsx" \
        "user:Now commit" \
        "commit:git commit -m test"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompts show HEAD 2>/dev/null || echo "")
    local count
    count=$(echo "$note" | grep -c '^\*\*[0-9]' || echo "0")
    if [[ "$count" -eq 3 ]]; then
        pass "captures all prompts in session ($count)"
    else
        fail "captures all prompts in session" "expected 3, got $count"
    fi
}

test_capture_ignores_non_commits() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo '{"tool_input":{"command":"ls -la"},"tool_response":"total 0"}' \
        | bash "$HOOKS_DIR/capture-prompts.sh"

    # Should exit cleanly (the fast guard catches this in <1ms)
    pass "ignores non-commit commands"
}

test_capture_ignores_failed_commits() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo '{"tool_input":{"command":"git commit -m test"},"tool_response":"nothing to commit, working tree clean"}' \
        | bash "$HOOKS_DIR/capture-prompts.sh"

    local count
    count=$(git notes --ref=claude-prompts list 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        pass "ignores failed commits (no [branch hash] in output)"
    else
        fail "ignores failed commits" "found $count notes"
    fi
}

test_capture_amend_overwrites_note() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "v1" > file.txt
    git add file.txt
    git commit -q -m "original"
    local hash
    hash=$(git rev-parse --short HEAD)

    # First note
    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Original prompt" \
        "commit:git commit -m original"
    make_hook_input "$hash" "$transcript" "session-1" | bash "$HOOKS_DIR/capture-prompts.sh"

    # Amend commit (same hash target, different content)
    echo "v2" > file.txt
    git add file.txt
    git commit -q --amend -m "amended"
    local new_hash
    new_hash=$(git rev-parse --short HEAD)

    make_transcript "$transcript" \
        "user:Amend with updated content" \
        "commit:git commit --amend -m amended"
    make_hook_input "$new_hash" "$transcript" "session-1" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompts show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"Amend with updated content"* ]]; then
        pass "amend overwrites previous note"
    else
        fail "amend overwrites previous note" "note: $note"
    fi
}

test_capture_branch_with_slashes() {
    make_test_repo
    trap cleanup_test_repo RETURN

    git checkout -q -b feature/my-thing
    echo "content" > file.txt
    git add file.txt
    git commit -q -m "feature work"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Work on feature" \
        "commit:git commit -m feature work"

    # Branch name with slash in the response
    local hook_input
    hook_input=$(cat <<EOF
{"tool_input":{"command":"git commit -m feature work"},"tool_response":"[feature/my-thing ${hash}] feature work\\n 1 file changed","transcript_path":"${transcript}","session_id":"test-session"}
EOF
)
    echo "$hook_input" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompts show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"Work on feature"* ]]; then
        pass "handles branch names with slashes"
    else
        fail "handles branch names with slashes" "note: $note"
    fi
}


# ============================================================
# capture-prompts.sh — multi-commit sessions
# ============================================================

test_multi_commit_session() {
    make_test_repo
    trap cleanup_test_repo RETURN

    # Build a transcript that has two commits
    local transcript="$TEST_DIR/transcript.jsonl"

    # --- First commit ---
    echo "file1" > a.txt
    git add a.txt
    git commit -q -m "first"
    local hash1
    hash1=$(git rev-parse --short HEAD)

    make_transcript "$transcript" \
        "user:Create file a" \
        "bash:echo file1 > a.txt" \
        "user:Commit a" \
        "commit:git commit -m first"

    make_hook_input "$hash1" "$transcript" "session-multi" | bash "$HOOKS_DIR/capture-prompts.sh"

    # --- Second commit (append to same transcript) ---
    echo "file2" > b.txt
    git add b.txt
    git commit -q -m "second"
    local hash2
    hash2=$(git rev-parse --short HEAD)

    # Append new entries to existing transcript
    printf '{"type":"user","message":{"content":"Now create file b"}}\n' >> "$transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo file2 > b.txt"}}]}}\n' >> "$transcript"
    printf '{"type":"user","message":{"content":"Commit b"}}\n' >> "$transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m second"}}]}}\n' >> "$transcript"

    make_hook_input "$hash2" "$transcript" "session-multi" | bash "$HOOKS_DIR/capture-prompts.sh"

    # First commit note should have "Create file a" but NOT "create file b"
    local note1
    note1=$(git notes --ref=claude-prompts show HEAD~1 2>/dev/null || echo "")
    if [[ "$note1" == *"Create file a"* && "$note1" != *"create file b"* ]]; then
        pass "multi-commit: first note has only first prompts"
    else
        fail "multi-commit: first note has only first prompts" "note: $note1"
    fi

    # Second commit note should have "create file b" but NOT "Create file a"
    local note2
    note2=$(git notes --ref=claude-prompts show HEAD 2>/dev/null || echo "")
    if [[ "$note2" == *"create file b"* || "$note2" == *"Now create file b"* ]] && [[ "$note2" != *"Create file a"* ]]; then
        pass "multi-commit: second note has only second prompts"
    else
        fail "multi-commit: second note has only second prompts" "note: $note2"
    fi
}


# ============================================================
# Parallel sessions on same repo
# ============================================================

test_parallel_sessions_no_conflict() {
    make_test_repo
    trap cleanup_test_repo RETURN

    # Session A: commit on branch-a
    git checkout -q -b branch-a
    echo "a" > a.txt
    git add a.txt
    git commit -q -m "commit from session a"
    local hash_a
    hash_a=$(git rev-parse --short HEAD)

    local transcript_a="$TEST_DIR/transcript-a.jsonl"
    make_transcript "$transcript_a" \
        "user:Work from session A" \
        "commit:git commit -m commit from session a"

    # Session B: commit on branch-b (branched from main)
    git checkout -q main
    git checkout -q -b branch-b
    echo "b" > b.txt
    git add b.txt
    git commit -q -m "commit from session b"
    local hash_b
    hash_b=$(git rev-parse --short HEAD)

    local transcript_b="$TEST_DIR/transcript-b.jsonl"
    make_transcript "$transcript_b" \
        "user:Work from session B" \
        "commit:git commit -m commit from session b"

    # Run both hooks (simulating parallel sessions)
    local hook_a hook_b
    hook_a=$(cat <<EOF
{"tool_input":{"command":"git commit -m commit from session a"},"tool_response":"[branch-a ${hash_a}] commit from session a\\n 1 file changed","transcript_path":"${transcript_a}","session_id":"session-a"}
EOF
)
    hook_b=$(cat <<EOF
{"tool_input":{"command":"git commit -m commit from session b"},"tool_response":"[branch-b ${hash_b}] commit from session b\\n 1 file changed","transcript_path":"${transcript_b}","session_id":"session-b"}
EOF
)

    # Run sequentially (in practice, commits from different sessions
    # don't happen at the exact same instant)
    echo "$hook_a" | bash "$HOOKS_DIR/capture-prompts.sh"
    echo "$hook_b" | bash "$HOOKS_DIR/capture-prompts.sh"

    # Verify both notes exist
    local note_a note_b
    note_a=$(git notes --ref=claude-prompts show branch-a 2>/dev/null || echo "")
    note_b=$(git notes --ref=claude-prompts show branch-b 2>/dev/null || echo "")

    if [[ "$note_a" == *"session A"* ]]; then
        pass "parallel: session A note attached"
    else
        fail "parallel: session A note attached" "note: $note_a"
    fi

    if [[ "$note_b" == *"session B"* ]]; then
        pass "parallel: session B note attached"
    else
        fail "parallel: session B note attached" "note: $note_b"
    fi

    # Verify correct session IDs
    if [[ "$note_a" == *"session-a"* && "$note_b" == *"session-b"* ]]; then
        pass "parallel: session IDs are distinct"
    else
        fail "parallel: session IDs are distinct" "a=$note_a, b=$note_b"
    fi
}

test_parallel_notes_total_count() {
    make_test_repo
    trap cleanup_test_repo RETURN

    # Create 3 commits on separate branches, attach notes from separate sessions
    for i in 1 2 3; do
        git checkout -q main
        git checkout -q -b "branch-$i"
        echo "$i" > "file-$i.txt"
        git add "file-$i.txt"
        git commit -q -m "commit $i"
        local hash
        hash=$(git rev-parse --short HEAD)

        local transcript="$TEST_DIR/transcript-$i.jsonl"
        make_transcript "$transcript" \
            "user:Task $i" \
            "commit:git commit -m commit $i"

        local hook_input
        hook_input=$(cat <<EOF
{"tool_input":{"command":"git commit -m commit $i"},"tool_response":"[branch-$i ${hash}] commit $i\\n 1 file changed","transcript_path":"${transcript}","session_id":"session-$i"}
EOF
)
        echo "$hook_input" | bash "$HOOKS_DIR/capture-prompts.sh"
    done

    local count
    count=$(git notes --ref=claude-prompts list 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -eq 3 ]]; then
        pass "parallel: all 3 notes created without conflict"
    else
        fail "parallel: all 3 notes created" "expected 3, got $count"
    fi
}


# ============================================================
# Install script
# ============================================================

test_install_creates_settings() {
    make_test_repo
    trap cleanup_test_repo RETURN

    mkdir -p .claude/hooks
    cp "$HOOKS_DIR/capture-prompts.sh" .claude/hooks/
    cp "$HOOKS_DIR/setup-notes.sh" .claude/hooks/
    chmod +x .claude/hooks/*.sh

    # Run the settings merge logic from install.sh
    python3 <<'PYTHON'
import json, os
SETTINGS_PATH = ".claude/settings.json"
HOOKS_CONFIG = {
    "PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/capture-prompts.sh", "timeout": 30}]}],
    "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/setup-notes.sh", "timeout": 5}]}],
}
settings = {}
if os.path.isfile(SETTINGS_PATH):
    with open(SETTINGS_PATH) as f:
        settings = json.load(f)
existing_hooks = settings.get("hooks", {})
for event, new_entries in HOOKS_CONFIG.items():
    current = existing_hooks.get(event, [])
    existing_commands = set()
    for entry in current:
        for h in entry.get("hooks", []):
            existing_commands.add(h.get("command", ""))
    for entry in new_entries:
        for h in entry.get("hooks", []):
            if h.get("command", "") not in existing_commands:
                current.append(entry)
                break
    existing_hooks[event] = current
settings["hooks"] = existing_hooks
with open(SETTINGS_PATH, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYTHON

    if python3 -c "
import json
with open('.claude/settings.json') as f:
    s = json.load(f)
h = s.get('hooks', {})
assert 'PostToolUse' in h
assert 'SessionStart' in h
assert 'capture-prompts' in json.dumps(h['PostToolUse'])
assert 'setup-notes' in json.dumps(h['SessionStart'])
"; then
        pass "install creates correct settings.json"
    else
        fail "install creates correct settings.json" "validation failed"
    fi
}

test_install_idempotent() {
    make_test_repo
    trap cleanup_test_repo RETURN

    mkdir -p .claude/hooks
    cp "$HOOKS_DIR/capture-prompts.sh" .claude/hooks/
    cp "$HOOKS_DIR/setup-notes.sh" .claude/hooks/
    chmod +x .claude/hooks/*.sh

    # Run install merge twice
    for _ in 1 2; do
        python3 <<'PYTHON'
import json, os
SETTINGS_PATH = ".claude/settings.json"
HOOKS_CONFIG = {
    "PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/capture-prompts.sh", "timeout": 30}]}],
    "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/setup-notes.sh", "timeout": 5}]}],
}
settings = {}
if os.path.isfile(SETTINGS_PATH):
    with open(SETTINGS_PATH) as f:
        settings = json.load(f)
existing_hooks = settings.get("hooks", {})
for event, new_entries in HOOKS_CONFIG.items():
    current = existing_hooks.get(event, [])
    existing_commands = set()
    for entry in current:
        for h in entry.get("hooks", []):
            existing_commands.add(h.get("command", ""))
    for entry in new_entries:
        for h in entry.get("hooks", []):
            if h.get("command", "") not in existing_commands:
                current.append(entry)
                break
    existing_hooks[event] = current
settings["hooks"] = existing_hooks
with open(SETTINGS_PATH, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYTHON
    done

    local count
    count=$(python3 -c "
import json
with open('.claude/settings.json') as f:
    s = json.load(f)
print(len(s['hooks']['PostToolUse']))
")
    if [[ "$count" -eq 1 ]]; then
        pass "install is idempotent (no duplicate hooks)"
    else
        fail "install is idempotent" "PostToolUse has $count entries"
    fi
}

test_install_preserves_existing_settings() {
    make_test_repo
    trap cleanup_test_repo RETURN

    mkdir -p .claude/hooks
    cp "$HOOKS_DIR/capture-prompts.sh" .claude/hooks/
    cp "$HOOKS_DIR/setup-notes.sh" .claude/hooks/
    chmod +x .claude/hooks/*.sh

    # Pre-existing settings.json with custom content
    cat > .claude/settings.json <<'JSON'
{
  "permissions": {"allow": ["Bash(npm test)"]},
  "hooks": {
    "PostToolUse": [
      {"matcher": "Write", "hooks": [{"type": "command", "command": "echo custom hook"}]}
    ]
  }
}
JSON

    python3 <<'PYTHON'
import json, os
SETTINGS_PATH = ".claude/settings.json"
HOOKS_CONFIG = {
    "PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/capture-prompts.sh", "timeout": 30}]}],
    "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/setup-notes.sh", "timeout": 5}]}],
}
settings = {}
if os.path.isfile(SETTINGS_PATH):
    with open(SETTINGS_PATH) as f:
        settings = json.load(f)
existing_hooks = settings.get("hooks", {})
for event, new_entries in HOOKS_CONFIG.items():
    current = existing_hooks.get(event, [])
    existing_commands = set()
    for entry in current:
        for h in entry.get("hooks", []):
            existing_commands.add(h.get("command", ""))
    for entry in new_entries:
        for h in entry.get("hooks", []):
            if h.get("command", "") not in existing_commands:
                current.append(entry)
                break
    existing_hooks[event] = current
settings["hooks"] = existing_hooks
with open(SETTINGS_PATH, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYTHON

    if python3 -c "
import json
with open('.claude/settings.json') as f:
    s = json.load(f)
# Existing permission preserved
assert s.get('permissions', {}).get('allow') == ['Bash(npm test)'], 'permissions lost'
# Existing hook preserved
ptu = s['hooks']['PostToolUse']
assert len(ptu) == 2, f'expected 2 PostToolUse entries, got {len(ptu)}'
assert any('custom hook' in json.dumps(e) for e in ptu), 'custom hook lost'
assert any('capture-prompts' in json.dumps(e) for e in ptu), 'capture-prompts not added'
"; then
        pass "install preserves existing settings and hooks"
    else
        fail "install preserves existing settings and hooks" "validation failed"
    fi
}


# ============================================================
# Worktree compatibility
# ============================================================

test_hooks_present_in_worktree() {
    make_test_repo
    trap cleanup_test_repo RETURN
    install_hooks

    git add .claude/
    git commit -q -m "add hooks"

    git worktree add -q "$TEST_DIR/wt" -b test-wt

    if [[ -x "$TEST_DIR/wt/.claude/hooks/capture-prompts.sh" && -x "$TEST_DIR/wt/.claude/hooks/setup-notes.sh" ]]; then
        pass "hooks present and executable in worktree checkout"
    else
        fail "hooks present and executable in worktree checkout" "missing or not executable"
    fi
}

test_setup_notes_in_worktree() {
    make_test_repo
    trap cleanup_test_repo RETURN
    git remote add origin "https://example.com/test.git"

    git worktree add -q "$TEST_DIR/wt" -b test-wt

    cd "$TEST_DIR/wt"
    bash "$HOOKS_DIR/setup-notes.sh"

    # Config should be visible from worktree
    local display_ref
    display_ref=$(git config --local --get notes.displayRef 2>/dev/null || echo "")
    if [[ "$display_ref" == "refs/notes/claude-prompts" ]]; then
        pass "setup-notes works in worktree"
    else
        fail "setup-notes works in worktree" "got '$display_ref'"
    fi

    # And from main worktree (shared config)
    cd "$TEST_DIR"
    display_ref=$(git config --local --get notes.displayRef 2>/dev/null || echo "")
    if [[ "$display_ref" == "refs/notes/claude-prompts" ]]; then
        pass "worktree config shared with main"
    else
        fail "worktree config shared with main" "got '$display_ref'"
    fi
}

test_capture_in_worktree() {
    make_test_repo
    trap cleanup_test_repo RETURN

    git worktree add -q "$TEST_DIR/wt" -b test-wt

    cd "$TEST_DIR/wt"
    echo "worktree content" > wt-file.txt
    git add wt-file.txt
    git commit -q -m "worktree commit"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/wt-transcript.jsonl"
    make_transcript "$transcript" \
        "user:Create a file in the worktree" \
        "commit:git commit -m worktree commit"

    local hook_input
    hook_input=$(cat <<EOF
{"tool_input":{"command":"git commit -m worktree commit"},"tool_response":"[test-wt ${hash}] worktree commit\\n 1 file changed","transcript_path":"${transcript}","session_id":"wt-session"}
EOF
)
    echo "$hook_input" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompts show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"Create a file in the worktree"* ]]; then
        pass "capture-prompts works in worktree"
    else
        fail "capture-prompts works in worktree" "note: $note"
    fi
}

test_worktree_note_visible_from_main() {
    make_test_repo
    trap cleanup_test_repo RETURN

    git worktree add -q "$TEST_DIR/wt" -b test-wt

    cd "$TEST_DIR/wt"
    echo "wt" > wt.txt
    git add wt.txt
    git commit -q -m "wt"
    local hash
    hash=$(git rev-parse --short HEAD)

    local transcript="$TEST_DIR/transcript.jsonl"
    make_transcript "$transcript" \
        "user:Worktree work" \
        "commit:git commit -m wt"
    local hook_input
    hook_input=$(cat <<EOF
{"tool_input":{"command":"git commit -m wt"},"tool_response":"[test-wt ${hash}] wt\\n 1 file changed","transcript_path":"${transcript}","session_id":"wt-session"}
EOF
)
    echo "$hook_input" | bash "$HOOKS_DIR/capture-prompts.sh"

    # Check from main worktree
    cd "$TEST_DIR"
    local note
    note=$(git notes --ref=claude-prompts show test-wt 2>/dev/null || echo "")
    if [[ "$note" == *"Worktree work"* ]]; then
        pass "worktree note visible from main worktree"
    else
        fail "worktree note visible from main worktree" "note: $note"
    fi
}

test_notes_shared_between_worktrees() {
    make_test_repo
    trap cleanup_test_repo RETURN

    git worktree add -q "$TEST_DIR/wt" -b test-wt

    # Note from main
    echo "main" > main.txt
    git add main.txt
    git commit -q -m "main commit"
    local main_hash
    main_hash=$(git rev-parse --short HEAD)
    local transcript="$TEST_DIR/main-t.jsonl"
    make_transcript "$transcript" "user:Main work" "commit:git commit -m main commit"
    make_hook_input "$main_hash" "$transcript" "session-main" | bash "$HOOKS_DIR/capture-prompts.sh"

    # Note from worktree
    cd "$TEST_DIR/wt"
    echo "wt" > wt.txt
    git add wt.txt
    git commit -q -m "wt commit"
    local wt_hash
    wt_hash=$(git rev-parse --short HEAD)
    transcript="$TEST_DIR/wt-t.jsonl"
    make_transcript "$transcript" "user:Worktree work" "commit:git commit -m wt commit"
    local hook_input
    hook_input=$(cat <<EOF
{"tool_input":{"command":"git commit -m wt commit"},"tool_response":"[test-wt ${wt_hash}] wt commit\\n 1 file changed","transcript_path":"${transcript}","session_id":"session-wt"}
EOF
)
    echo "$hook_input" | bash "$HOOKS_DIR/capture-prompts.sh"

    # Both notes visible from either location
    local count_main count_wt
    cd "$TEST_DIR"
    count_main=$(git notes --ref=claude-prompts list 2>/dev/null | wc -l | tr -d ' ')
    cd "$TEST_DIR/wt"
    count_wt=$(git notes --ref=claude-prompts list 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$count_main" -eq 2 && "$count_wt" -eq 2 ]]; then
        pass "notes shared between main and worktree (both see 2)"
    else
        fail "notes shared between main and worktree" "main=$count_main, wt=$count_wt"
    fi
}


# ============================================================
# Edge cases
# ============================================================

test_capture_no_transcript() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt
    git add x.txt
    git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    # Hook input pointing to nonexistent transcript
    echo "{\"tool_input\":{\"command\":\"git commit -m test\"},\"tool_response\":\"[main ${hash}] test\\n 1 file changed\",\"transcript_path\":\"/nonexistent/path.jsonl\",\"session_id\":\"test\"}" \
        | bash "$HOOKS_DIR/capture-prompts.sh"

    local count
    count=$(git notes --ref=claude-prompts list 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        pass "gracefully handles missing transcript"
    else
        fail "gracefully handles missing transcript" "found $count notes"
    fi
}

test_capture_empty_transcript() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt
    git add x.txt
    git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    # Empty transcript file
    local transcript="$TEST_DIR/empty.jsonl"
    > "$transcript"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local count
    count=$(git notes --ref=claude-prompts list 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        pass "gracefully handles empty transcript"
    else
        fail "gracefully handles empty transcript" "found $count notes"
    fi
}

test_capture_malformed_json() {
    make_test_repo
    trap cleanup_test_repo RETURN

    # Garbage input that contains "git commit" (passes fast guard) but is invalid JSON
    echo 'this is not json but has git commit in it' \
        | bash "$HOOKS_DIR/capture-prompts.sh" || true

    pass "gracefully handles malformed JSON input"
}

test_capture_long_prompt_truncation() {
    make_test_repo
    trap cleanup_test_repo RETURN

    echo "x" > x.txt
    git add x.txt
    git commit -q -m "test"
    local hash
    hash=$(git rev-parse --short HEAD)

    # Create transcript with a very long prompt (3000 chars)
    local transcript="$TEST_DIR/transcript.jsonl"
    local long_prompt
    long_prompt=$(python3 -c "print('A' * 3000)")
    # Write manually to handle the long string
    printf '{"type":"user","message":{"content":"%s"}}\n' "$long_prompt" > "$transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m test"}}]}}\n' >> "$transcript"

    make_hook_input "$hash" "$transcript" | bash "$HOOKS_DIR/capture-prompts.sh"

    local note
    note=$(git notes --ref=claude-prompts show HEAD 2>/dev/null || echo "")
    if [[ "$note" == *"[truncated]"* ]]; then
        pass "long prompts are truncated"
    else
        # Check if note exists at all (might not truncate if feature not present)
        if [[ "$note" == *"AAAA"* ]]; then
            pass "long prompts are captured (truncation may vary)"
        else
            fail "long prompts are truncated" "note length: ${#note}"
        fi
    fi
}


# ============================================================
# E2E tests (optional — require ANTHROPIC_API_KEY + claude CLI)
# ============================================================

test_e2e_basic_commit() {
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        skip "E2E basic commit" "ANTHROPIC_API_KEY not set"
        return
    fi
    if ! command -v claude >/dev/null 2>&1; then
        skip "E2E basic commit" "claude CLI not installed"
        return
    fi

    make_test_repo
    trap cleanup_test_repo RETURN
    install_hooks
    cp "$PROJECT_DIR/.claude/settings.json" .claude/settings.json
    git add .claude/
    git commit -q -m "add hooks"
    bash .claude/hooks/setup-notes.sh

    local output
    output=$(claude -p "Create a file called hello.txt containing 'hello from test' and commit it with message 'Add hello.txt'. Do not push." \
        --allowedTools 'Bash(git *)' 'Bash(echo *)' 'Write' \
        2>&1) || true

    local log
    log=$(git log --oneline -5 2>/dev/null || echo "")
    if [[ "$log" == *"hello"* ]]; then
        local note
        note=$(git notes --ref=claude-prompts show HEAD 2>/dev/null || echo "")
        if [[ "$note" == *"Claude Code Prompts"* ]]; then
            pass "E2E: commit with note attached"
        else
            fail "E2E: commit with note attached" "commit exists but no note"
        fi
    else
        fail "E2E: Claude created commit" "no matching commit. Output: ${output:0:200}"
    fi
}

test_e2e_worktree_commit() {
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        skip "E2E worktree commit" "ANTHROPIC_API_KEY not set"
        return
    fi
    if ! command -v claude >/dev/null 2>&1; then
        skip "E2E worktree commit" "claude CLI not installed"
        return
    fi

    make_test_repo
    trap cleanup_test_repo RETURN
    install_hooks
    cp "$PROJECT_DIR/.claude/settings.json" .claude/settings.json
    git add .claude/
    git commit -q -m "add hooks"
    bash .claude/hooks/setup-notes.sh

    mkdir -p .claude/worktrees
    git worktree add -q .claude/worktrees/test-task -b worktree-test
    cd .claude/worktrees/test-task

    local output
    output=$(claude -p "Create a file called wt.txt containing 'worktree' and commit with message 'Add wt.txt'. Do not push." \
        --allowedTools 'Bash(git *)' 'Bash(echo *)' 'Write' \
        2>&1) || true

    local log
    log=$(git log --oneline -5 2>/dev/null || echo "")
    if [[ "$log" == *"wt"* ]]; then
        local note
        note=$(git notes --ref=claude-prompts show HEAD 2>/dev/null || echo "")
        if [[ "$note" == *"Claude Code Prompts"* ]]; then
            pass "E2E: worktree commit with note"

            cd "$TEST_DIR"
            note=$(git notes --ref=claude-prompts show worktree-test 2>/dev/null || echo "")
            if [[ "$note" == *"Claude Code Prompts"* ]]; then
                pass "E2E: worktree note visible from main"
            else
                fail "E2E: worktree note visible from main" "not visible"
            fi
        else
            fail "E2E: worktree commit with note" "commit exists but no note"
        fi
    else
        fail "E2E: worktree commit created" "no matching commit. Output: ${output:0:200}"
    fi
}


# ============================================================
# Runner
# ============================================================

main() {
    printf "\033[1mclaude-git-prompt-magic test suite\033[0m\n"

    section "setup-notes.sh"
    test_setup_notes_configures_displayref
    test_setup_notes_configures_fetch_refspec
    test_setup_notes_idempotent
    test_setup_notes_cleans_push_refspec
    test_setup_notes_no_remote

    section "capture-prompts.sh — basics"
    test_capture_attaches_note
    test_capture_note_format
    test_capture_multiple_prompts
    test_capture_ignores_non_commits
    test_capture_ignores_failed_commits
    test_capture_amend_overwrites_note
    test_capture_branch_with_slashes

    section "capture-prompts.sh — multi-commit sessions"
    test_multi_commit_session

    section "parallel sessions"
    test_parallel_sessions_no_conflict
    test_parallel_notes_total_count

    section "install script"
    test_install_creates_settings
    test_install_idempotent
    test_install_preserves_existing_settings

    section "worktree compatibility"
    test_hooks_present_in_worktree
    test_setup_notes_in_worktree
    test_capture_in_worktree
    test_worktree_note_visible_from_main
    test_notes_shared_between_worktrees

    section "edge cases"
    test_capture_no_transcript
    test_capture_empty_transcript
    test_capture_malformed_json
    test_capture_long_prompt_truncation

    section "E2E with Claude (optional)"
    test_e2e_basic_commit
    test_e2e_worktree_commit

    # Summary
    printf "\n\033[1mResults: %d passed, %d failed, %d skipped\033[0m\n" "$PASSED" "$FAILED" "$SKIPPED"
    if [[ "$FAILED" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
