---
name: adversarial-review
description: Run an adversarial code review by spawning a safecodex reviewer in a herdr split pane, waiting for it to finish, and interrogating its findings. Use whenever the user asks for an adversarial review, red-team review, second opinion, "attack this diff/plan", "poke holes in this", or wants their working changes challenged before shipping - even if they don't name safecodex or herdr explicitly.
---

# Adversarial Review

`scripts/reviewer.sh` drives the whole reviewer lifecycle - it builds the prompt,
splits a herdr pane, launches `safecodex`, submits, waits through permission
prompts, and verifies the output file. Your job is the two things it can't do:
**state the intent** and **verify the findings**.

`<skill-dir>` below is this skill's directory (shown when the skill loads) -
substitute its absolute path.

The reviewer runs interactively in the split pane, so the user can watch it,
approve prompts, or steer it.

## 1. State the intent, then start

Determine what to review (default: the working diff) and - critically - the
**intent**: what the author is trying to achieve. The reviewer challenges whether
the work achieves the intent well, not whether the intent is correct. If you
can't infer the intent, ask.

Write it to a file (one or two sentences, always in English), show it to the
user, and start:

```bash
cat > /tmp/intent.md <<'EOF'
<what the author is trying to achieve>
EOF
<skill-dir>/scripts/reviewer.sh start --intent-file /tmp/intent.md --diff
```

Target selection:

- `--diff` - working diff (`git diff HEAD`) plus untracked files. The default.
- `--file PATH` - review a plan, doc, or specific file. Repeatable.
- Both - e.g. a diff reviewed against the plan it implements.
- `--timeout MS` - overall budget (default 900000).

Never paste diffs or file contents yourself; the flags collect them.

Run `start` with the Bash tool's `run_in_background: true`. A review can outlast
the foreground Bash timeout cap (which would kill the wait loop mid-review), and
backgrounding keeps the session free while the reviewer works - pick up the
output when the background task completes. `ask` is quick enough to run in the
foreground.

On success it prints `REVIEW_FILE=...`. On failure it exits non-zero with a
diagnostic and a tail of the reviewer pane - relay that and stop; the pane stays
open for inspection.

If the reviewer hits a permission prompt, the script notifies the user, prints a
`BLOCKED` note, and keeps waiting - tell the user to approve it in the pane.

## 2. Interrogate the findings

Read `$REVIEW_FILE`. **Do not relay it verbatim** - the reviewer is adversarial
by instruction and will sometimes manufacture or overstate problems. Check each
finding against the actual code and mark it:

- **Confirmed** - you verified the failure scenario is real.
- **Disputed** - you checked; it's wrong or doesn't apply. Say why in one line.
- **Unverified** - plausible but not cheaply confirmable. Say what would settle it.

The session stays open. To press on a finding worth pursuing:

```bash
<skill-dir>/scripts/reviewer.sh ask "Finding 3 assumes X is nil - where does that happen?"
```

`ask` submits, waits, and prints the reviewer's answer. Weigh it before settling
the verdict - an answer is not automatically right either.

## 3. Report and clean up

```bash
<skill-dir>/scripts/reviewer.sh close
```

Leave the pane open only on failure. Report:

```markdown
**Intent:** <the stated intent>

## High
1. <finding> - Confirmed: <one-line verification note> (`file:line`)
## Medium
...
## Low
...
```

Order high → low, confirmed before disputed. If everything of substance is
disputed, say so plainly - "the reviewer found nothing that holds up" is a valid,
useful outcome.

## Reference

- `reviewer.sh status` - agent status plus a pane tail, when something looks stuck.
- State for the active review lives in `/tmp/adversarial-review/state.env`, so
  `ask`/`status`/`close` need no arguments. One review at a time.
- Launch is via `herdr pane run` (an interactive shell) because `safecodex` may
  be a shell alias - `herdr agent start` spawns a raw process where aliases don't
  resolve.
