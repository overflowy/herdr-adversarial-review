---
name: adversarial-review
description: Run an adversarial code review by spawning a safecodex reviewer in a herdr split pane, waiting for it to finish, and interrogating its findings. Use whenever the user asks for an adversarial review, red-team review, second opinion, "attack this diff/plan", "poke holes in this", or wants their working changes challenged before shipping — even if they don't name safecodex or herdr explicitly.
---

# Adversarial Review

Spawn `safecodex` (a wrapped claude CLI) as an adversarial reviewer in a herdr split pane, hand it the work plus its stated intent, wait for it to finish, then interrogate its findings before relaying them. The reviewer's job is to find real problems, not validate the work; your job afterward is to verify which of its findings are real.

The reviewer runs **interactively** (no `-p`): the TUI is live in the split pane, so the user can watch it work, approve permission prompts, or jump in and steer. Herdr detects claude-family agents natively, so completion is tracked via agent status, not output scraping. `safecodex` may be a shell alias/function, so launch it with `herdr pane run` (interactive shell) — never `herdr agent start -- argv`, which spawns a raw process where aliases don't resolve.

## 1. Identify the target and the intent

Identify what to review from context: recent diffs, referenced plans, or the user's message. Default to the working diff (`git diff HEAD`, plus untracked files worth including); if the user points at a plan or file, review that instead.

Then determine the **intent** — what the author is trying to achieve. This is critical: the reviewer challenges whether the work achieves the intent well, not whether the intent is correct. State the intent explicitly (one or two sentences, shown to the user) before proceeding. If you cannot infer it, ask.

## 2. Prepare the handoff files

```bash
mkdir -p /tmp/adversarial-review
ID=$(openssl rand -hex 4)
PROMPT_FILE="/tmp/adversarial-review/prompt-$ID.md"
REVIEW_FILE="/tmp/adversarial-review/review-$ID.md"
```

Write the full prompt to `$PROMPT_FILE` (diffs can be large — never paste them into a TUI input). Essential sections, in order:

1. The stated intent.
2. The code or diff to review (full text, with file paths).
3. The reviewer charge, including the output path:

> You are an adversarial reviewer. Your job is to find real problems, not validate the work. Be specific — cite files, lines, and concrete failure scenarios. Rate each finding: high (blocks ship), medium (should fix), low (worth noting). Write findings as a numbered markdown list to `$REVIEW_FILE` (create the file; that file is your only output channel). Work alone: do not spawn subagents or delegate — read the code yourself so every finding comes from one accountable read.

## 3. Spawn the reviewer

```bash
herdr pane split --current --direction right --ratio 0.4 --no-focus
# → returns JSON with the new pane_id; capture it as $PANE
herdr pane rename $PANE "adversarial-reviewer"
herdr pane run $PANE "safecodex --disallowedTools Task,Agent --disable-slash-commands"
herdr wait agent-status $PANE --status idle --timeout 30000   # TUI up and ready
```

Then hand it the task — a short pointer, not the prompt itself:

```bash
herdr agent send $PANE "Read $PROMPT_FILE and follow its instructions exactly."
herdr pane send-keys $PANE enter
```

(`agent send` writes literal text without submitting; the `enter` keypress submits it.)

## 4. Wait for completion

Status flow is idle → working → idle. Confirm it actually started before waiting for it to finish, otherwise the second wait can match the *initial* idle and return instantly:

```bash
herdr wait agent-status $PANE --status working --timeout 20000   # started (a timeout here means the send didn't take — check the pane)
herdr wait agent-status $PANE --status idle --timeout 600000     # finished
```

If the idle wait times out, run `herdr agent get $PANE`:

- **blocked** — the reviewer is waiting on a permission prompt in the pane. Tell the user; the pane is interactive, they can approve it there. Then resume waiting.
- **working** — genuinely long review; resume waiting or read progress with `herdr pane read $PANE --source recent-unwrapped --lines 60`.

When idle, verify `$REVIEW_FILE` exists and is non-empty. If not, read the pane scrollback to see what went wrong and report that instead of proceeding.

## 5. Interrogate the findings

Read `$REVIEW_FILE`. Do not relay it verbatim — the reviewer is adversarial by instruction and will sometimes manufacture or overstate problems. For each finding, check it against the actual code and mark it:

- **Confirmed** — you verified the failure scenario is real.
- **Disputed** — you checked and it's wrong or doesn't apply; say why in one line.
- **Unverified** — plausible but you couldn't cheaply confirm; say what would settle it.

The reviewer session is still open: for a disputed or unclear finding worth pressing on, send a follow-up (`herdr agent send` + `enter`, then the same working → idle wait) and weigh its answer before settling the verdict.

## 6. Report and clean up

Close the reviewer pane once verdicts are settled (`herdr pane close $PANE`); leave it open only on failure so the user can inspect it. Optionally `herdr notification show "Adversarial review done"` if the run took long.

Report to the user:

```markdown
**Intent:** <the stated intent>

## High
1. <finding> — Confirmed/Disputed/Unverified: <one-line verification note> (`file:line`)
## Medium
...
## Low
...
```

Order findings high → low, confirmed before disputed. If everything of substance is disputed, say so plainly — "the reviewer found nothing that holds up" is a valid, useful outcome.
