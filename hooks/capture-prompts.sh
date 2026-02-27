#!/usr/bin/env bash
set -euo pipefail

# PostToolUse hook: captures Claude Code prompts and attaches them to git commits
# as git notes in the refs/notes/claude-prompts namespace.
#
# Receives PostToolUse JSON on stdin. Exits in <1ms for non-commit commands.

# Fast guard: skip if stdin doesn't mention "git commit" at all (~1ms exit)
INPUT=$(cat)
if [[ "$INPUT" != *"git commit"* ]]; then
    exit 0
fi

# Delegate all JSON parsing and note creation to Python
HOOK_INPUT="$INPUT" python3 <<'PYTHON'
import json, os, re, subprocess, sys
from datetime import datetime, timezone

# Patterns that match common secret/credential formats.
# Each tuple: (compiled regex, replacement text)
SECRET_PATTERNS = [
    # Anthropic API keys
    (re.compile(r"sk-ant-api\d{2}-[A-Za-z0-9_-]{86}-[A-Za-z0-9_-]{6}AA"), "[REDACTED_ANTHROPIC_KEY]"),
    # OpenAI API keys
    (re.compile(r"sk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}"), "[REDACTED_OPENAI_KEY]"),
    (re.compile(r"sk-proj-[A-Za-z0-9_-]{40,}"), "[REDACTED_OPENAI_KEY]"),
    # AWS access keys
    (re.compile(r"AKIA[0-9A-Z]{16}"), "[REDACTED_AWS_KEY]"),
    # AWS secret keys (40 char base64-ish after common prefixes)
    (re.compile(r"(?<=[:= '\"])[A-Za-z0-9/+=]{40}(?=[ '\"\n])"), "[REDACTED_AWS_SECRET]"),
    # GitHub tokens
    (re.compile(r"gh[pousr]_[A-Za-z0-9_]{36,}"), "[REDACTED_GITHUB_TOKEN]"),
    (re.compile(r"github_pat_[A-Za-z0-9_]{22}_[A-Za-z0-9_]{59}"), "[REDACTED_GITHUB_TOKEN]"),
    # Generic long hex/base64 strings that look like secrets (64+ chars)
    (re.compile(r"(?<![A-Za-z0-9/])[A-Za-z0-9/+=_-]{64,}(?![A-Za-z0-9/])"), "[REDACTED_LONG_SECRET]"),
    # Bearer tokens
    (re.compile(r"Bearer\s+[A-Za-z0-9._~+/=-]{20,}"), "Bearer [REDACTED_TOKEN]"),
    # Generic "secret/key/token/password = value" patterns
    (re.compile(r"(?i)(api[_-]?key|secret[_-]?key|auth[_-]?token|password|access[_-]?token|private[_-]?key)\s*[=:]\s*['\"]?[^\s'\"]{8,}"), r"\1=[REDACTED]"),
]


def redact_secrets(text):
    """Replace likely secrets/credentials with redaction markers."""
    for pattern, replacement in SECRET_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def main():
    try:
        hook_data = json.loads(os.environ["HOOK_INPUT"])
    except (json.JSONDecodeError, KeyError):
        return

    # Validate this is a Bash command containing "git commit"
    tool_input = hook_data.get("tool_input", {})
    command = tool_input.get("command", "") if isinstance(tool_input, dict) else ""
    if "git commit" not in command:
        return

    # Check tool_response for successful commit pattern: [branch hash]
    response = hook_data.get("tool_response", "")
    if isinstance(response, dict):
        response = json.dumps(response)
    match = re.search(r"\[[\w/.+-]+ ([a-f0-9]{7,})\]", str(response))
    if not match:
        return
    commit_hash = match.group(1)

    # Locate transcript
    transcript_path = hook_data.get("transcript_path", "")
    session_id = hook_data.get("session_id", "")
    if not transcript_path or not os.path.isfile(transcript_path):
        return
    if not session_id:
        return

    # Extract session data since the previous git commit
    data = extract_session_data(transcript_path)
    if not data["prompts"]:
        return

    # Format note
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    note = format_note(session_id, timestamp, data)

    # Attach as git note (--force overwrites if amending)
    result = subprocess.run(
        ["git", "notes", "--ref=claude-prompts", "add", "-f", "-m", note, commit_hash],
        capture_output=True,
        timeout=10,
    )
    if result.returncode != 0:
        return

    # Push the note to remote (best-effort, silent failure if offline)
    subprocess.run(
        ["git", "push", "origin", "refs/notes/claude-prompts"],
        capture_output=True,
        timeout=15,
    )


def extract_session_data(transcript_path):
    """Walk backward through the transcript collecting prompts and metadata.

    Returns a dict with prompts, models, token usage, tool counts, etc.
    Stops at the previous git commit boundary (or session start).
    Skips the current commit's tool_use record so we capture the
    prompts that led *to* this commit, not past it.
    """
    records = []
    with open(transcript_path, "r") as f:
        for line in f:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                records.append(json.loads(stripped))
            except json.JSONDecodeError:
                continue

    prompts = []
    found_current_commit = False

    # Metadata accumulators
    models_seen = []       # ordered by first appearance
    models_set = set()
    tools_count = {}       # tool_name -> count
    mcp_servers_set = set()
    user_turns = 0
    assistant_turns = 0
    tokens_in = 0
    tokens_out = 0
    cache_read = 0
    cache_write = 0
    slug = ""
    client_version = ""
    git_branch = ""
    permission_mode = ""

    def _finalize():
        prompts.reverse()
        return {
            "prompts": prompts,
            "models": models_seen,
            "slug": slug,
            "client_version": client_version,
            "git_branch": git_branch,
            "permission_mode": permission_mode,
            "user_turns": user_turns,
            "assistant_turns": assistant_turns,
            "tokens_in": tokens_in,
            "tokens_out": tokens_out,
            "cache_read": cache_read,
            "cache_write": cache_write,
            "tools": tools_count,
            "mcp_servers": sorted(mcp_servers_set),
        }

    for record in reversed(records):
        rec_type = record.get("type", "")

        # Detect git-commit tool_use inside assistant messages
        if rec_type == "assistant":
            msg = record.get("message", {})
            content = msg.get("content", [])
            is_commit = False
            if isinstance(content, list):
                for part in content:
                    if (
                        isinstance(part, dict)
                        and part.get("type") == "tool_use"
                        and part.get("name") == "Bash"
                        and "git commit" in part.get("input", {}).get("command", "")
                    ):
                        if not found_current_commit:
                            found_current_commit = True
                            is_commit = True
                            break
                        else:
                            if prompts:
                                return _finalize()
                            # No prompts between commits, keep looking

            # Gather assistant metadata (only within our window)
            if found_current_commit and not is_commit:
                assistant_turns += 1
                # Model
                model = msg.get("model", "")
                if model and model not in models_set:
                    models_seen.append(model)
                    models_set.add(model)
                # Token usage
                usage = msg.get("usage", {})
                tokens_in += usage.get("input_tokens", 0)
                tokens_out += usage.get("output_tokens", 0)
                cache_read += usage.get("cache_read_input_tokens", 0)
                cache_write += usage.get("cache_creation_input_tokens", 0)
                # Tool use counts
                if isinstance(content, list):
                    for part in content:
                        if isinstance(part, dict) and part.get("type") == "tool_use":
                            tool_name = part.get("name", "")
                            if tool_name:
                                tools_count[tool_name] = tools_count.get(tool_name, 0) + 1
                                # Detect MCP servers from mcp__server__method pattern
                                if tool_name.startswith("mcp__"):
                                    parts = tool_name.split("__")
                                    if len(parts) >= 3:
                                        mcp_servers_set.add(parts[1])

        # Collect user prompts (only after we've passed the current commit)
        if found_current_commit and rec_type == "user":
            user_turns += 1
            # Capture metadata from user records
            if not slug:
                slug = record.get("slug", "")
            if not client_version:
                client_version = record.get("version", "")
            if not git_branch:
                git_branch = record.get("gitBranch", "")
            # Iterating backward: first value seen = chronologically last
            raw_mode = record.get("permissionMode", "")
            if raw_mode and not permission_mode:
                permission_mode = raw_mode

            text = extract_text(record)
            if text:
                if len(text) > 2000:
                    text = text[:2000] + "... [truncated]"
                mode = extract_mode(record)
                if mode:
                    text = f"[{mode}] {text}"
                prompts.append(text)

    return _finalize()


MODE_LABELS = {
    "plan": "plan",
    "dontAsk": "auto-accept",
    "bypassPermissions": "bypass",
    "acceptEdits": "accept-edits",
}


def format_note(session_id, timestamp, data):
    """Format the v2 git note from session data."""
    lines = [
        "## Claude Code Prompts",
        "",
        "<!-- format:v2 -->",
        "",
        f"**Session**: {session_id}",
    ]
    if data.get("slug"):
        lines.append(f"**Slug**: {data['slug']}")
    lines.append(f"**Captured**: {timestamp}")
    if data.get("git_branch"):
        lines.append(f"**Branch**: {data['git_branch']}")
    if data.get("models"):
        lines.append(f"**Model**: {', '.join(data['models'])}")
    if data.get("client_version"):
        lines.append(f"**Client**: {data['client_version']}")
    if data.get("permission_mode"):
        label = MODE_LABELS.get(data["permission_mode"], data["permission_mode"])
        lines.append(f"**Permission**: {label}")

    # Prompts section
    lines.append("")
    lines.append("### Prompts")
    lines.append("")
    for i, prompt in enumerate(data["prompts"], 1):
        lines.append(f"**{i}.** {redact_secrets(prompt)}")
        lines.append("")

    # Stats section (only if we have token data)
    has_tokens = (
        data.get("tokens_in", 0) > 0
        or data.get("tokens_out", 0) > 0
    )
    if has_tokens or data.get("user_turns", 0) > 0:
        lines.append("### Stats")
        lines.append("")
        lines.append("| Metric | Value |")
        lines.append("|--------|-------|")
        if data.get("user_turns", 0) > 0 or data.get("assistant_turns", 0) > 0:
            lines.append(
                f"| Turns | {data['user_turns']} user, {data['assistant_turns']} assistant |"
            )
        if data.get("tokens_in", 0) > 0:
            lines.append(f"| Tokens in | {data['tokens_in']:,} |")
        if data.get("tokens_out", 0) > 0:
            lines.append(f"| Tokens out | {data['tokens_out']:,} |")
        if data.get("cache_read", 0) > 0:
            lines.append(f"| Cache read | {data['cache_read']:,} |")
        if data.get("cache_write", 0) > 0:
            lines.append(f"| Cache write | {data['cache_write']:,} |")
        lines.append("")

    # Tools section (only if any tools were used)
    if data.get("tools"):
        # Sort by frequency descending
        sorted_tools = sorted(data["tools"].items(), key=lambda x: -x[1])
        tool_parts = [f"{name}({count})" for name, count in sorted_tools]
        lines.append("### Tools")
        lines.append("")
        lines.append(" ".join(tool_parts))
        lines.append("")

    # MCP Servers section (only if any detected)
    if data.get("mcp_servers"):
        lines.append("### MCP Servers")
        lines.append("")
        lines.append(", ".join(data["mcp_servers"]))
        lines.append("")

    return "\n".join(lines)


def extract_mode(record):
    """Return a readable mode label if the user record has a non-default permissionMode."""
    raw = record.get("permissionMode", "")
    return MODE_LABELS.get(raw, "")


def extract_text(record):
    """Extract plain text from a user message record."""
    msg_content = record.get("message", {}).get("content", "")
    if isinstance(msg_content, str):
        return msg_content.strip()
    if isinstance(msg_content, list):
        parts = []
        for part in msg_content:
            if isinstance(part, dict) and part.get("type") == "text":
                t = part.get("text", "").strip()
                if t:
                    parts.append(t)
        return "\n".join(parts).strip()
    return ""


if __name__ == "__main__":
    main()
PYTHON
