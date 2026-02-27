# claude-git-prompt-magic

Automatically captures Claude Code prompts and attaches them to git commits using [git notes](https://git-scm.com/docs/git-notes). Zero dependencies beyond Python 3 and bash.

## Why prompts belong in version control

The prompts that shape AI-generated code are as important as the code itself. When they live alongside commits, developers can learn from each other. Seeing how a teammate guided an AI through a tricky refactor teaches you as much as reading the refactor. It also creates an audit trail: not just *what* changed, but *why* and *how* it was directed. That matters for code review, onboarding, and compliance. We think every AI-assisted change should carry the context of its creation.

## Install

```bash
claude plugin install github:Trailblaze-work/claude-git-prompt-magic
```

To install for your whole team (commits the plugin reference to `.claude/settings.json`):

```bash
claude plugin install github:Trailblaze-work/claude-git-prompt-magic --scope project
```

Toggle the plugin on or off:

```bash
claude plugin disable prompt-magic
claude plugin enable prompt-magic
```

## How it works

A Claude Code [PostToolUse hook](https://docs.anthropic.com/en/docs/claude-code/hooks) fires after every Bash command. For non-commits it exits in ~1ms. When it detects a successful `git commit`, it rises to the occasion:

1. Extracts the commit hash from the tool output
2. Reads the session transcript (JSONL)
3. Follows the breadcrumbs backward to collect every user prompt since the previous commit
4. Attaches them as a git note in `refs/notes/claude-prompts`
5. Pushes the note to origin

A SessionStart hook auto-configures `git fetch` to pull notes and `git log` to display them.

Manual commits are completely unaffected. The hooks only fire inside Claude Code.

## What it looks like

After a Claude Code session that makes a commit:

```
$ git log --notes=claude-prompts -1

commit a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0
Author: Jane Smith <jane@example.com>
Date:   Wed Feb 26 15:23:03 2026 +0100

    Add user avatar upload with size validation

Notes (claude-prompts):
    ## Claude Code Prompts

    <!-- format:v2 -->

    **Session**: f0d06f5e-5e70-4085-960f-bccb9dd11afb
    **Slug**: starry-hugging-otter
    **Captured**: 2026-02-26T14:23:05Z
    **Branch**: feature/avatar-upload
    **Model**: claude-opus-4-6
    **Client**: 2.1.59
    **Permission**: accept-edits

    ### Prompts

    **1.** Add avatar upload to the user profile page. Max 2MB, jpeg and png only.

    **2.** Also add a circular crop preview before saving

    **3.** [auto-accept] Looks good, commit and push

    ### Stats

    | Metric | Value |
    |--------|-------|
    | Turns | 3 user, 8 assistant |
    | Tokens in | 45,230 |
    | Tokens out | 12,847 |
    | Cache read | 128,450 |
    | Cache write | 8,200 |

    ### Tools

    Edit(4) Bash(6) Read(3) Grep(2) Glob(1)

    ### MCP Servers

    notion, slack
```

View prompts for any specific commit:

```
$ git notes --ref=claude-prompts show HEAD

## Claude Code Prompts

<!-- format:v2 -->

**Session**: f0d06f5e-5e70-4085-960f-bccb9dd11afb
**Slug**: starry-hugging-otter
**Captured**: 2026-02-26T14:23:05Z
**Branch**: feature/avatar-upload
**Model**: claude-opus-4-6
**Client**: 2.1.59

### Prompts

**1.** Add avatar upload to the user profile page. Max 2MB, jpeg and png only.

**2.** Also add a circular crop preview before saving

**3.** Looks good, commit and push
```

Manual commits have no note and just work normally:

```
$ git log --oneline --notes=claude-prompts -3

a1b2c3d Add user avatar upload with size validation
        Notes (claude-prompts):
            ## Claude Code Prompts
            ...

e4f5a6b Fix typo in README
c7d8e9f Update CI config to Node 22
```

### Note format

Notes use a structured markdown format designed to be readable in terminals, rendered on GitHub, and parseable by scripts.

| Field | Description |
|-------|-------------|
| `**Session**` | Claude Code session UUID |
| `**Slug**` | Human-readable session slug (if available) |
| `**Captured**` | UTC timestamp when the note was created |
| `**Branch**` | Git branch at time of commit |
| `**Model**` | Model(s) used, comma-separated if multiple |
| `**Client**` | Claude Code CLI version |
| `**Permission**` | Permission mode (`auto-accept`, `accept-edits`, `plan`, `bypass`) |

**Sections** (all optional, only present when data exists):

- **### Prompts** — numbered user prompts with `[mode]` prefix when non-default
- **### Stats** — markdown table with turn counts and token usage
- **### Tools** — compact `ToolName(count)` list sorted by frequency
- **### MCP Servers** — comma-separated list of MCP server names detected from tool usage

## Uninstall

```bash
claude plugin uninstall prompt-magic
```

To also clean up local git config:

```bash
git config --local --unset notes.displayRef
git config --local --unset-all remote.origin.fetch "+refs/notes/claude-prompts:refs/notes/claude-prompts"
```

## Worktree support

Works out of the box with `claude --worktree` and manual `git worktree` setups. The plugin hooks are loaded by Claude Code automatically, git notes are stored in the shared `.git` directory so they're visible across all worktrees, and git config is shared automatically.

## Testing

```bash
bash test/run-tests.sh
```

Set `ANTHROPIC_API_KEY` and install the `claude` CLI to also run E2E tests that exercise the full flow with real Claude Code sessions.

## Limitations

- Only captures prompts from the current session. If you work across multiple sessions before committing, only the committing session's prompts are recorded.
- Each commit triggers a `git push origin refs/notes/claude-prompts` to sync notes. This adds a few seconds of latency per commit (up to 15s with a slow or unreachable remote). The push fails silently if offline.
- Requires Python 3 (pre-installed on macOS and most Linux).

## License

MIT

---

<p align="center">
  <a href="https://trailblaze.work">
    <img src="https://raw.githubusercontent.com/Trailblaze-work/trailblaze.work/main/trailblaze-mark.svg" alt="Trailblaze" width="50" />
  </a>
</p>
<h3 align="center">Built by <a href="https://trailblaze.work">Trailblaze</a></h3>
<p align="center">
  We help companies deploy AI across their workforce.<br>
  Strategy, implementation, training, and governance.<br><br>
  <a href="mailto:hello@trailblaze.work"><strong>hello@trailblaze.work</strong></a>
</p>
