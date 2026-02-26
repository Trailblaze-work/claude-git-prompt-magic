#!/usr/bin/env bash
set -euo pipefail

REPO="Trailblaze-work/claude-git-prompt-magic"
RAW="https://raw.githubusercontent.com/$REPO/main"

# --- Preflight checks ---

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: not inside a git repository." >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required." >&2
    exit 1
fi

echo "Installing claude-git-prompt-magic..."

# --- Download hook scripts ---

mkdir -p .claude/hooks

curl -fsSL "$RAW/hooks/capture-prompts.sh" -o .claude/hooks/capture-prompts.sh
curl -fsSL "$RAW/hooks/setup-notes.sh"     -o .claude/hooks/setup-notes.sh
chmod +x .claude/hooks/capture-prompts.sh .claude/hooks/setup-notes.sh

echo "  Hooks installed to .claude/hooks/"

# --- Merge into .claude/settings.json ---

python3 <<'PYTHON'
import json, os

SETTINGS_PATH = ".claude/settings.json"
HOOKS_CONFIG = {
    "PostToolUse": [
        {
            "matcher": "Bash",
            "hooks": [
                {
                    "type": "command",
                    "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/capture-prompts.sh",
                    "timeout": 30,
                }
            ],
        }
    ],
    "SessionStart": [
        {
            "matcher": "startup",
            "hooks": [
                {
                    "type": "command",
                    "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/setup-notes.sh",
                    "timeout": 5,
                }
            ],
        }
    ],
}

settings = {}
if os.path.isfile(SETTINGS_PATH):
    with open(SETTINGS_PATH) as f:
        settings = json.load(f)

existing_hooks = settings.get("hooks", {})

# Merge each event, avoiding duplicates by checking command path
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

echo "  Settings updated in .claude/settings.json"

# --- Update .gitignore ---

touch .gitignore
for pattern in ".DS_Store" ".claude/settings.local.json"; do
    if ! grep -qxF "$pattern" .gitignore; then
        echo "$pattern" >> .gitignore
    fi
done

echo "  .gitignore updated"

# --- Run setup-notes.sh now ---

bash .claude/hooks/setup-notes.sh

echo "  Git configured to display and fetch prompt notes"

echo ""
echo "Done! Every Claude Code commit will now capture the prompts that created it."
echo "View them with: git log --notes=claude-prompts"
