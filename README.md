# claude-git-prompt-magic

Automatically captures coding-assistant prompts and attaches them to git commits using [git notes](https://git-scm.com/docs/git-notes). Zero dependencies beyond Python 3 and bash.

## Install

### Claude Code

Run this inside any git repo:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Trailblaze-work/claude-git-prompt-magic/main/install.sh)
```

This creates `.claude/hooks/` with two shell scripts and adds hook configuration to `.claude/settings.json`.

### Making it automatic for your team

If you **commit the `.claude/` directory**, every developer who clones the repo and uses Claude Code gets prompt capture baked in — zero setup on their end. This is the recommended approach.

`.claude/settings.json` is Claude Code's [shared project config](https://docs.anthropic.com/en/docs/claude-code/settings). Committing it also shares any other project-level Claude Code settings (like enabled plugins or allowed tools) with the team — which is generally the point of that file. Personal overrides go in `.claude/settings.local.json`, which the installer adds to `.gitignore`.

If you'd rather **not commit `.claude/`**, each developer runs the install one-liner above individually. Same result, just not automatic.

### Codex

Run this inside any git repo:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Trailblaze-work/claude-git-prompt-magic/main/install-codex.sh)
```

This installs Codex parser scripts into `.codex/hooks/`:

- `capture-codex-prompts.sh`
- `codex_prompt_extractor.py`

It also installs an idempotent shim block into the repo's effective `post-commit` hook that executes `.codex/hooks/capture-codex-prompts.sh`.

If you commit `.codex/hooks/`, updates to Codex capture logic propagate to teammates through normal `git pull` (no stale copied hook scripts).

## How it works

A Claude Code [PostToolUse hook](https://docs.anthropic.com/en/docs/claude-code/hooks) fires after every Bash command. For non-commits it exits in ~1ms. When it detects a successful `git commit`, it rises to the occasion:

1. Extracts the commit hash from the tool output
2. Reads the session transcript (JSONL)
3. Follows the breadcrumbs backward to collect every user prompt since the previous commit
4. Attaches them as a git note in `refs/notes/claude-prompts`
5. Pushes the note to origin

A SessionStart hook auto-configures `git fetch` to pull notes and `git log` to display them.

Manual commits are completely unaffected — the hooks only fire inside Claude Code.

For Codex, a `post-commit` hook runs after each commit:

1. Hook shim resolves repo root and executes `.codex/hooks/capture-codex-prompts.sh`
2. Capture script reads `CODEX_THREAD_ID` from the environment (exits fast if missing)
3. Parser finds latest session file matching that thread in `~/.codex/sessions`
4. Parser pairs `exec_command` `git commit` calls with outputs to find commit boundaries
5. Collects user prompts from session start up to the current commit boundary
6. Filters bootstrap messages (`AGENTS.md` injection + `<environment_context>`)
7. Attaches prompts as a git note in `refs/notes/claude-prompts`
8. Pushes that note ref to origin (best effort)

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

    **Session**: f0d06f5e-5e70-4085-960f-bccb9dd11afb
    **Captured**: 2026-02-26T14:23:05Z

    ### Prompts

    **1.** Add avatar upload to the user profile page. Max 2MB, jpeg and png only.

    **2.** Also add a circular crop preview before saving

    **3.** Looks good, commit and push
```

View prompts for any specific commit:

```
$ git notes --ref=claude-prompts show HEAD

## Claude Code Prompts

**Session**: f0d06f5e-5e70-4085-960f-bccb9dd11afb
**Captured**: 2026-02-26T14:23:05Z

### Prompts

**1.** Add avatar upload to the user profile page. Max 2MB, jpeg and png only.

**2.** Also add a circular crop preview before saving

**3.** Looks good, commit and push
```

Manual commits have no note — they just work normally:

```
$ git log --oneline --notes=claude-prompts -3

a1b2c3d Add user avatar upload with size validation
        Notes (claude-prompts):
            ## Claude Code Prompts
            ...

e4f5a6b Fix typo in README
c7d8e9f Update CI config to Node 22
```

## Uninstall

```bash
# Remove hooks and settings
rm .claude/hooks/capture-prompts.sh .claude/hooks/setup-notes.sh
# Edit .claude/settings.json to remove the "hooks" key
# Remove local git config
git config --local --unset notes.displayRef
git config --local --unset-all remote.origin.fetch "+refs/notes/claude-prompts:refs/notes/claude-prompts"
```

For Codex installs:

```bash
rm .codex/hooks/capture-codex-prompts.sh .codex/hooks/codex_prompt_extractor.py
# Remove the marker block from the effective post-commit hook
# (typically .git/hooks/post-commit unless core.hooksPath is customized):
#   # >>> codex-git-prompt-magic >>>
#   ...
#   # <<< codex-git-prompt-magic <<<
git config --local --unset notes.displayRef
git config --local --unset-all remote.origin.fetch "+refs/notes/claude-prompts:refs/notes/claude-prompts"
```

## Limitations

- Only captures prompts from the current session. If you work across multiple sessions before committing, only the committing session's prompts are recorded.
- Requires Python 3 (pre-installed on macOS and most Linux).
- Codex capture requires `CODEX_THREAD_ID` to be present in the commit process environment.
- Codex relies on local `~/.codex/sessions` JSONL structure.
- Codex notes grow across commits in the same session by design (session-start capture).

## Development

Run parser tests:

```bash
python3 -m unittest -v tests/test_codex_prompt_extractor.py
```

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
