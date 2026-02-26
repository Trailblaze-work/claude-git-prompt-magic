#!/usr/bin/env python3
"""Extract user prompts from a Codex session JSONL for a specific git commit."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional


COMMIT_RE = re.compile(r"\[[\w./+-]+ ([a-f0-9]{7,40})\]")
BOOTSTRAP_PREFIXES = (
    "# AGENTS.md instructions for ",
    "<environment_context>",
)


@dataclass(frozen=True)
class CommitEvent:
    call_id: str
    call_index: int
    output_index: int
    commit_hash: str


def parse_records(session_path: Path) -> list[dict]:
    records: list[dict] = []
    with session_path.open("r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                records.append(json.loads(stripped))
            except json.JSONDecodeError:
                continue
    return records


def parse_exec_command(arguments: object) -> str:
    if not isinstance(arguments, str):
        return ""
    try:
        payload = json.loads(arguments)
    except json.JSONDecodeError:
        return ""
    if isinstance(payload, dict):
        cmd = payload.get("cmd", "")
        if isinstance(cmd, str):
            return cmd
    return ""


def extract_commit_events(records: Iterable[dict]) -> list[CommitEvent]:
    pending_call_indexes: dict[str, int] = {}
    events: list[CommitEvent] = []

    for idx, record in enumerate(records):
        if record.get("type") != "response_item":
            continue

        payload = record.get("payload", {})
        if not isinstance(payload, dict):
            continue

        payload_type = payload.get("type")

        if payload_type == "function_call" and payload.get("name") == "exec_command":
            command = parse_exec_command(payload.get("arguments"))
            if "git commit" not in command:
                continue
            call_id = payload.get("call_id", "")
            if isinstance(call_id, str) and call_id:
                pending_call_indexes[call_id] = idx
            continue

        if payload_type != "function_call_output":
            continue

        call_id = payload.get("call_id", "")
        if not isinstance(call_id, str) or call_id not in pending_call_indexes:
            continue

        output = payload.get("output", "")
        if not isinstance(output, str):
            continue

        match = COMMIT_RE.search(output)
        if not match:
            continue

        events.append(
            CommitEvent(
                call_id=call_id,
                call_index=pending_call_indexes.pop(call_id),
                output_index=idx,
                commit_hash=match.group(1).lower(),
            )
        )

    return events


def find_commit_index(events: list[CommitEvent], commit_hash: Optional[str]) -> Optional[int]:
    if not events:
        return None

    if not commit_hash:
        return len(events) - 1

    normalized = commit_hash.lower()
    for idx in range(len(events) - 1, -1, -1):
        event_hash = events[idx].commit_hash
        if event_hash.startswith(normalized) or normalized.startswith(event_hash):
            return idx
    return None


def extract_message_text(payload: dict) -> str:
    content = payload.get("content", [])

    if isinstance(content, str):
        return content.strip()

    if not isinstance(content, list):
        return ""

    parts: list[str] = []
    for part in content:
        if not isinstance(part, dict):
            continue
        if part.get("type") not in ("input_text", "text"):
            continue
        text = part.get("text", "")
        if not isinstance(text, str):
            continue
        text = text.strip()
        if text:
            parts.append(text)

    return "\n".join(parts).strip()


def is_bootstrap_message(text: str) -> bool:
    stripped = text.strip()
    return any(stripped.startswith(prefix) for prefix in BOOTSTRAP_PREFIXES)


def extract_prompts_for_commit(records: list[dict], commit_hash: Optional[str]) -> list[str]:
    events = extract_commit_events(records)
    commit_idx = find_commit_index(events, commit_hash)
    current_boundary: Optional[int] = None
    if commit_idx is None:
        # post-commit can run before the current commit's tool output is flushed
        # to the session file; in that case, capture prompts after the latest
        # known commit boundary until EOF.
        previous_boundary = events[-1].call_index if events else -1
    else:
        current_boundary = events[commit_idx].call_index
        previous_boundary = events[commit_idx - 1].call_index if commit_idx > 0 else -1

    prompts: list[str] = []

    for idx, record in enumerate(records):
        if idx <= previous_boundary:
            continue
        if current_boundary is not None and idx >= current_boundary:
            continue
        if record.get("type") != "response_item":
            continue
        payload = record.get("payload", {})
        if not isinstance(payload, dict):
            continue
        if payload.get("type") != "message" or payload.get("role") != "user":
            continue

        text = extract_message_text(payload)
        if not text or is_bootstrap_message(text):
            continue

        if len(text) > 2000:
            text = text[:2000] + "... [truncated]"

        prompts.append(text)

    return prompts


def find_latest_session_file(thread_id: str, sessions_root: Path) -> Optional[Path]:
    if not thread_id:
        return None
    if not sessions_root.is_dir():
        return None

    pattern = f"*-{thread_id}.jsonl"
    candidates = list(sessions_root.rglob(pattern))
    if not candidates:
        return None

    return max(candidates, key=lambda path: path.stat().st_mtime)


def format_note(session_id: str, prompts: list[str]) -> str:
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines = [
        "## Codex Prompts",
        "",
        f"**Session**: {session_id}",
        f"**Captured**: {timestamp}",
        "",
        "### Prompts",
        "",
    ]

    for idx, prompt in enumerate(prompts, 1):
        lines.append(f"**{idx}.** {prompt}")
        lines.append("")

    return "\n".join(lines)


def build_note(thread_id: str, commit_hash: Optional[str], sessions_root: Path) -> str:
    session_file = find_latest_session_file(thread_id, sessions_root)
    if session_file is None:
        return ""

    records = parse_records(session_file)
    prompts = extract_prompts_for_commit(records, commit_hash)
    if not prompts:
        return ""

    return format_note(thread_id, prompts)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--thread-id", required=True, help="CODEX_THREAD_ID value")
    parser.add_argument("--commit-hash", help="Target commit hash (HEAD by default)")
    parser.add_argument(
        "--sessions-root",
        default=str(Path("~/.codex/sessions").expanduser()),
        help="Path to the Codex sessions directory",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    sessions_root = Path(args.sessions_root).expanduser()
    note = build_note(args.thread_id, args.commit_hash, sessions_root)
    if note:
        sys.stdout.write(note)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
