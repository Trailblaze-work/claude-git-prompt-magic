#!/usr/bin/env bash
set -euo pipefail

REPO="Trailblaze-work/claude-git-prompt-magic"
RAW="${CODEX_PROMPT_MAGIC_RAW:-https://raw.githubusercontent.com/$REPO/main}"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: not inside a git repository." >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required." >&2
    exit 1
fi

echo "Installing Codex prompt capture..."

REPO_ROOT="$(git rev-parse --show-toplevel)"

# If only a global hooksPath is configured, keep Codex setup repo-local.
if ! git config --local --get core.hooksPath >/dev/null 2>&1; then
    git config --local core.hooksPath .git/hooks
fi

HOOK_DIR="$(git rev-parse --git-path hooks)"
mkdir -p "$HOOK_DIR"

PROJECT_HOOK_DIR="$REPO_ROOT/.codex/hooks"
mkdir -p "$PROJECT_HOOK_DIR"

curl -fsSL "$RAW/hooks/capture-codex-prompts.sh" -o "$PROJECT_HOOK_DIR/capture-codex-prompts.sh"
curl -fsSL "$RAW/hooks/codex_prompt_extractor.py" -o "$PROJECT_HOOK_DIR/codex_prompt_extractor.py"
chmod +x "$PROJECT_HOOK_DIR/capture-codex-prompts.sh" "$PROJECT_HOOK_DIR/codex_prompt_extractor.py"

echo "  Codex scripts installed to .codex/hooks/"
echo "  Git hook directory: $HOOK_DIR/"

POST_COMMIT="$HOOK_DIR/post-commit"
if [[ ! -f "$POST_COMMIT" ]]; then
    cat >"$POST_COMMIT" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
HOOK
fi

python3 - "$POST_COMMIT" <<'PYTHON'
import re
import sys
from pathlib import Path

hook_path = Path(sys.argv[1])
text = hook_path.read_text(encoding="utf-8")

begin = "# >>> codex-git-prompt-magic >>>"
end = "# <<< codex-git-prompt-magic <<<"
block = (
    f"{begin}\n"
    'REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"\n'
    'SCRIPT="$REPO_ROOT/.codex/hooks/capture-codex-prompts.sh"\n'
    'if [[ -x "$SCRIPT" ]]; then\n'
    '    "$SCRIPT" || true\n'
    "fi\n"
    f"{end}\n"
)

pattern = re.compile(
    re.escape(begin) + r".*?" + re.escape(end) + r"\n?",
    flags=re.DOTALL,
)

if pattern.search(text):
    updated = pattern.sub(block, text)
else:
    if not text.endswith("\n"):
        text += "\n"
    updated = text + "\n" + block

hook_path.write_text(updated, encoding="utf-8")
PYTHON

chmod +x "$POST_COMMIT"
echo "  post-commit hook configured"
echo "  Post-commit shim points to repo-tracked .codex/hooks scripts"

git config --local notes.displayRef "refs/notes/claude-prompts"
FETCH_REF="+refs/notes/claude-prompts:refs/notes/claude-prompts"
if ! git config --local --get-all remote.origin.fetch 2>/dev/null | grep -qF "$FETCH_REF"; then
    git config --add --local remote.origin.fetch "$FETCH_REF"
fi
if git config --local --get-all remote.origin.push 2>/dev/null | grep -qF "refs/notes/claude-prompts"; then
    git config --unset-all --local remote.origin.push "refs/notes/claude-prompts" 2>/dev/null || true
fi

echo "  Git configured to display/fetch prompt notes"
echo ""
echo "Done! Codex commits now capture prompts when CODEX_THREAD_ID is present."
echo "For team-wide updates, commit .codex/hooks/."
echo "View notes with: git log --notes=claude-prompts"
