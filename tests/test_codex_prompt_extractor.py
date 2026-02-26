import json
import sys
import tempfile
import unittest
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path


def load_module():
    module_path = Path(__file__).resolve().parents[1] / "hooks" / "codex_prompt_extractor.py"
    spec = spec_from_file_location("codex_prompt_extractor", module_path)
    module = module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def user_message(text):
    return {
        "type": "response_item",
        "payload": {
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": text}],
        },
    }


def assistant_message(text):
    return {
        "type": "response_item",
        "payload": {
            "type": "message",
            "role": "assistant",
            "content": [{"type": "output_text", "text": text}],
        },
    }


def commit_call(call_id, cmd="bash -lc 'git commit -m \"msg\"'"):
    return {
        "type": "response_item",
        "payload": {
            "type": "function_call",
            "name": "exec_command",
            "call_id": call_id,
            "arguments": json.dumps({"cmd": cmd}),
        },
    }


def commit_output(call_id, short_hash, branch="main"):
    return {
        "type": "response_item",
        "payload": {
            "type": "function_call_output",
            "call_id": call_id,
            "output": f"Output:\n[{branch} {short_hash}] commit message\n",
        },
    }


class CodexPromptExtractorTests(unittest.TestCase):
    def setUp(self):
        self.m = load_module()

    def test_extract_commit_events_pairs_call_and_output(self):
        records = [
            user_message("hello"),
            commit_call("c1"),
            commit_output("c1", "abc1234"),
            commit_call("c2"),
            commit_output("c2", "def5678"),
        ]

        events = self.m.extract_commit_events(records)
        self.assertEqual([e.commit_hash for e in events], ["abc1234", "def5678"])
        self.assertEqual([e.call_id for e in events], ["c1", "c2"])

    def test_extract_prompts_between_previous_and_current_commit(self):
        records = [
            user_message("initial ask"),
            assistant_message("working"),
            commit_call("c1"),
            commit_output("c1", "abc1234"),
            user_message("add retries"),
            user_message("add tests"),
            assistant_message("done"),
            commit_call("c2", "bash -lc 'git add . && git commit -m \"second\" && git push'"),
            commit_output("c2", "def5678"),
        ]

        prompts = self.m.extract_prompts_for_commit(records, "def5678")
        self.assertEqual(prompts, ["add retries", "add tests"])

    def test_filters_bootstrap_user_messages(self):
        records = [
            user_message("# AGENTS.md instructions for /path\n\n<INSTRUCTIONS>..."),
            user_message("<environment_context>\n  <cwd>/tmp</cwd>\n</environment_context>"),
            user_message("real request"),
            commit_call("c1"),
            commit_output("c1", "abc1234"),
        ]

        prompts = self.m.extract_prompts_for_commit(records, "abc1234")
        self.assertEqual(prompts, ["real request"])

    def test_find_session_file_for_thread_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "2026" / "02" / "26"
            target.mkdir(parents=True)
            good = target / "rollout-2026-02-26T18-26-35-019c9afc-f57f-7c11-83a5-fbd6bc5ef93a.jsonl"
            good.write_text("{}\n", encoding="utf-8")

            other = target / "rollout-2026-02-26T11-00-00-019c1111-aaaa-7c11-83a5-fbd6bc5ef93a.jsonl"
            other.write_text("{}\n", encoding="utf-8")

            found = self.m.find_latest_session_file(
                "019c9afc-f57f-7c11-83a5-fbd6bc5ef93a", root
            )

            self.assertEqual(found, good)

    def test_extract_prompts_when_current_commit_event_not_yet_flushed(self):
        records = [
            user_message("old request"),
            commit_call("c1"),
            commit_output("c1", "abc1234"),
            user_message("new request 1"),
            assistant_message("in progress"),
            user_message("new request 2"),
            # no c2 function_call_output yet (post-commit race)
        ]

        prompts = self.m.extract_prompts_for_commit(records, "def5678")
        self.assertEqual(prompts, ["new request 1", "new request 2"])


if __name__ == "__main__":
    unittest.main()
