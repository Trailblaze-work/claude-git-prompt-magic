# claude-git-prompt-magic

Automatically captures Claude Code prompts and attaches them to git commits using [git notes](https://git-scm.com/docs/git-notes). Zero dependencies beyond Python 3 and bash.

## Install

Run this inside any git repo:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Trailblaze-work/claude-git-prompt-magic/main/install.sh)
```

This creates `.claude/hooks/` with two shell scripts and adds hook configuration to `.claude/settings.json`.

### Making it automatic for your team

If you **commit the `.claude/` directory**, every developer who clones the repo and uses Claude Code gets prompt capture baked in — zero setup on their end. This is the recommended approach.

`.claude/settings.json` is Claude Code's [shared project config](https://docs.anthropic.com/en/docs/claude-code/settings). Committing it also shares any other project-level Claude Code settings (like enabled plugins or allowed tools) with the team — which is generally the point of that file. Personal overrides go in `.claude/settings.local.json`, which the installer adds to `.gitignore`.

If you'd rather **not commit `.claude/`**, each developer runs the install one-liner above individually. Same result, just not automatic.

## How it works

A Claude Code [PostToolUse hook](https://docs.anthropic.com/en/docs/claude-code/hooks) fires after every Bash command. For non-commits it exits in ~1ms. When it detects a successful `git commit`, it rises to the occasion:

1. Extracts the commit hash from the tool output
2. Reads the session transcript (JSONL)
3. Follows the breadcrumbs backward to collect every user prompt since the previous commit
4. Attaches them as a git note in `refs/notes/claude-prompts`
5. Pushes the note to origin

A SessionStart hook auto-configures `git fetch` to pull notes and `git log` to display them.

Manual commits are completely unaffected — the hooks only fire inside Claude Code.

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

## Limitations

- Only captures prompts from the current session. If you work across multiple sessions before committing, only the committing session's prompts are recorded.
- Requires Python 3 (pre-installed on macOS and most Linux).

## License

MIT

---

<sub>Built by <a href="https://trailblaze.work"><strong>Trailblaze</strong></a> — we help companies deploy AI across their workforce. Strategy, implementation, training, and governance. <a href="mailto:hello@trailblaze.work">Get in touch</a>.</sub>
