---
name: writing-commit-messages
description: >-
  Writes Git commit messages. Activates when the user asks to write
  a commit message, draft a commit message, or similar.
---

# Writing Commit Messages

Follow the Commits section of the root `AGENTS.md`. Summary:

## Format

```
<type>(<optional scope>): <subject>

<one-line motivation>
- <decision, trade-off, or invariant>
- <decision, trade-off, or invariant>
```

- **Type**: feat, fix, docs, refactor, test, chore, perf, build, ci,
  style, or revert. Pick the most accurate one. Add `!` for breaking
  changes (removed config options, build flags, or CLI actions).
- **Scope**: optional, short and lowercase, taken from the changed
  paths (`terminal`, `font`, `config`, `macos`, `build`, ...).
- **Subject**: lowercase, imperative mood, no trailing period, under
  72 characters (50 is ideal).
- **Body**: include it only when the why is not obvious. Lead with one
  line of motivation, then bullets for decisions, trade-offs and
  invariants. Do not restate the diff. Wrap at about 72 characters.

## Privacy

This repo is public. Never describe the maintainer's machine or habits:
no names, home paths, installed or missing software, shell, config
contents, hardware, OS build, disk, or file permissions. Justify the
change with code and product facts only.

## Workflow

- Run a diff to see what changed since the last commit.
- Stage explicit paths only, never `git add -A`.
- Scan the staged diff for secrets. If one is present, stop and tell
  the user instead of committing.
- Write the message to a file and commit with `git commit -F <file>`.
- Do not push; leave that to the user.
