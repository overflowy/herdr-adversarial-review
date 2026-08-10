#!/usr/bin/env bash
# Drive an adversarial reviewer agent in a herdr split pane.
#
#   reviewer.sh start --intent-file F [--diff] [--file PATH]... [--timeout MS]
#   reviewer.sh ask "<question>" [--timeout MS]
#   reviewer.sh status
#   reviewer.sh close
#
# `start` builds the prompt, spawns the reviewer, submits, waits through
# permission prompts, and prints the path to the finished review.

# No `set -u`: macOS ships bash 3.2, where empty-array expansion under -u aborts.
# shellcheck disable=SC2153  # AGENT/PANE are assigned by sourcing $STATE in load_state
set -o pipefail

DIR="${ADVERSARIAL_REVIEW_DIR:-/tmp/adversarial-review}"
STATE="$DIR/state.env"
REVIEWER_CMD="${ADVERSARIAL_REVIEW_CMD:-safecodex --disallowedTools Task,Agent,WebSearch,WebFetch --effort medium --disable-slash-commands}"
READY_TIMEOUT_MS="${ADVERSARIAL_REVIEW_READY_TIMEOUT_MS:-60000}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf 'note: %s\n' "$*" >&2; }

# Run a herdr command, failing loudly on an API error envelope.
herdr_ok() {
  local out
  out=$(herdr "$@" 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
  if printf '%s' "$out" | jq -e 'has("error")' >/dev/null 2>&1; then
    printf 'herdr %s: %s\n' "$1 ${2:-}" "$(printf '%s' "$out" | jq -r '.error.message')" >&2
    return 1
  fi
  printf '%s' "$out"
}

# `herdr pane read` emits plain text, not a JSON envelope like the other
# subcommands — piping it through jq swallowed every diagnostic tail.
pane_tail() {
  herdr pane read "$1" --source recent-unwrapped --lines "${2:-40}" 2>/dev/null
}

# idle | working | blocked | done | unknown | gone
agent_status() {
  local out
  out=$(herdr agent get "$1" 2>/dev/null) || { echo gone; return; }
  printf '%s' "$out" | jq -r 'if has("error") then "gone" else (.result.agent.agent_status // "unknown") end'
}

# Wait until the agent is idle/done, surfacing (but not aborting on) blocked.
# $1 = agent target, $2 = total timeout ms. Returns 1 on timeout.
wait_settled() {
  local agent=$1 total=$2 chunk=60000 spent=0 slice st notified=0 gone=0
  while ((spent < total)); do
    slice=$((total - spent)); ((slice > chunk)) && slice=$chunk
    herdr agent wait "$agent" --until idle --until "done" --timeout "$slice" >/dev/null 2>&1 && return 0
    spent=$((spent + slice))
    st=$(agent_status "$agent")
    case "$st" in
      idle|done) return 0 ;;
      gone|unknown)
        ((gone++)); ((gone >= 2)) && die "reviewer agent disappeared (status: $st)" ;;
      blocked)
        gone=0
        if ((notified == 0)); then
          notified=1
          herdr notification show "Adversarial reviewer needs input" \
            --body "Approve the prompt in the reviewer pane." --sound request >/dev/null 2>&1
          note "reviewer is BLOCKED on a prompt in its pane — approve it there; still waiting"
        fi ;;
      *) gone=0; notified=0 ;;
    esac
  done
  return 1
}

load_state() {
  [[ -f "$STATE" ]] || die "no active review (missing $STATE) — run 'reviewer.sh start' first"
  # shellcheck disable=SC1090
  . "$STATE"
}

# $1=id $2=pane $3=agent $4=prompt $5=review
write_state() {
  printf 'ID=%s\nPANE=%s\nAGENT=%s\nPROMPT_FILE=%s\nREVIEW_FILE=%s\n' \
    "$1" "$2" "$3" "$4" "$5" >"$STATE"
}

# herdr only registers a pane's agent once it detects the TUI, a beat after
# `pane run`. Until then `agent wait` hard-errors with agent_not_found in
# milliseconds instead of waiting, so a single call races the launch and reports
# a timeout that never happened. Retry across that window on wall-clock.
wait_ready() {
  local pane=$1 deadline=$((SECONDS + ($2 + 999) / 1000))
  while :; do
    herdr agent wait "$pane" --until idle --timeout 1000 >/dev/null 2>&1 && return 0
    ((SECONDS >= deadline)) && return 1
    sleep 0.25
  done
}

cmd_start() {
  local intent_file="" want_diff=0 timeout=900000
  local -a extra_files=()
  while (($#)); do
    case "$1" in
      --intent-file) intent_file=${2:?}; shift 2 ;;
      --diff)        want_diff=1; shift ;;
      --file)        extra_files+=("${2:?}"); shift 2 ;;
      --timeout)     timeout=${2:?}; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [[ -s "$intent_file" ]] || die "--intent-file is required and must be non-empty"
  ((want_diff || ${#extra_files[@]})) || die "give the reviewer something to read: --diff and/or --file PATH"
  if ((${#extra_files[@]} > 0)); then
    for f in "${extra_files[@]}"; do [[ -f "$f" ]] || die "no such file: $f"; done
  fi

  mkdir -p "$DIR"
  local id prompt review
  id=$(openssl rand -hex 4)
  prompt="$DIR/prompt-$id.md"
  review="$DIR/review-$id.md"

  if ((want_diff && ${#extra_files[@]} == 0)) \
     && [[ -z "$(git diff HEAD)" && -z "$(git ls-files --others --exclude-standard)" ]]; then
    die "--diff found no working changes and no --file was given; nothing to review"
  fi

  # 5-backtick fences so fenced content inside the reviewed files can't escape.
  {
    echo "# Adversarial review"
    echo
    echo "## Intent"
    echo
    cat "$intent_file"
    echo
    if ((want_diff)); then
      echo "## Working diff (\`git diff HEAD\`)"
      echo
      echo '`````diff'
      git diff HEAD
      echo '`````'
      echo
      local untracked_header=0
      while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        if ((untracked_header == 0)); then
          untracked_header=1
          printf '## Untracked files\n\n'
        fi
        printf '### %s\n\n`````\n' "$f"; cat "$f"; printf '\n`````\n\n'
      done < <(git ls-files --others --exclude-standard)
    fi
    if ((${#extra_files[@]} > 0)); then
      for f in "${extra_files[@]}"; do
        printf '## %s\n\n`````\n' "$f"; cat "$f"; printf '\n`````\n\n'
      done
    fi
    cat <<EOF
## Your charge

You are an adversarial reviewer. Your job is to find real problems, not to
validate the work. Judge whether the work achieves the stated intent well — not
whether the intent itself is correct.

Be specific: cite files, lines, and concrete failure scenarios. Rate each
finding **high** (blocks ship), **medium** (should fix), or **low** (worth
noting).

Write your findings in English — regardless of the language of the reviewed
content — as a numbered markdown list to \`$review\` (create the file;
that file is your only output channel). Work alone: do not spawn subagents or
delegate — read the code yourself so every finding comes from one accountable
read.
EOF
  } >"$prompt" || die "failed to build $prompt"

  local pane
  pane=$(herdr_ok pane split --current --direction right --ratio 0.4 --cwd "$PWD" --no-focus \
    | jq -r '.result.pane.pane_id') || die "could not split a pane"
  [[ -n "$pane" && "$pane" != null ]] || die "pane split returned no pane_id"

  # Record the pane before anything that can fail, so a failed start is still
  # closable — `close` and `status` need PANE, not a finished handshake.
  write_state "$id" "$pane" "$pane" "$prompt" "$review"

  herdr pane rename "$pane" "adversarial-reviewer" >/dev/null 2>&1
  herdr_ok pane run "$pane" "$REVIEWER_CMD" >/dev/null || die "could not launch: $REVIEWER_CMD"

  wait_ready "$pane" "$READY_TIMEOUT_MS" || die "reviewer TUI never became ready. Pane $pane tail:
$(pane_tail "$pane")"

  local agent="rev-$id"
  herdr agent rename "$pane" "$agent" >/dev/null 2>&1 || agent="$pane"
  write_state "$id" "$pane" "$agent" "$prompt" "$review"

  local out
  out=$(herdr agent prompt "$agent" "Read $prompt and follow its instructions exactly." \
        --wait --timeout "$timeout" 2>&1)
  if printf '%s' "$out" | jq -e '.error.code == "agent_prompt_stalled"' >/dev/null 2>&1; then
    die "the prompt never reached the reviewer. Pane $pane tail:
$(pane_tail "$pane")"
  fi

  wait_settled "$agent" "$timeout" || die "review still unfinished after ${timeout}ms (status: $(agent_status "$agent")). Pane $pane tail:
$(pane_tail "$pane")"

  [[ -s "$review" ]] || die "reviewer finished but wrote nothing to $review. Pane $pane tail:
$(pane_tail "$pane")"

  printf 'ok: review ready\nREVIEW_FILE=%s\n' "$review"
}

cmd_ask() {
  local question=${1:?usage: reviewer.sh ask "<question>"} timeout=300000
  shift
  while (($#)); do
    case "$1" in
      --timeout) timeout=${2:?}; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  load_state

  local n=1 answer
  while [[ -e "$DIR/answer-$ID-$n.md" ]]; do ((n++)); done
  answer="$DIR/answer-$ID-$n.md"

  local out
  out=$(herdr agent prompt "$AGENT" \
    "$question

Write your answer to \`$answer\` (create it; that file is your only output channel)." \
    --wait --timeout "$timeout" 2>&1)
  if printf '%s' "$out" | jq -e '.error.code == "agent_prompt_stalled"' >/dev/null 2>&1; then
    die "follow-up never reached the reviewer. Pane $PANE tail:
$(pane_tail "$PANE")"
  fi

  wait_settled "$AGENT" "$timeout" || die "no answer after ${timeout}ms (status: $(agent_status "$AGENT"))"
  [[ -s "$answer" ]] || die "reviewer answered in-pane instead of writing $answer. Pane $PANE tail:
$(pane_tail "$PANE")"
  cat "$answer"
}

cmd_status() {
  load_state
  printf 'agent=%s pane=%s status=%s review=%s\n' \
    "$AGENT" "$PANE" "$(agent_status "$AGENT")" "$REVIEW_FILE"
  pane_tail "$PANE" 60
}

cmd_close() {
  load_state
  herdr pane close "$PANE" >/dev/null 2>&1
  rm -f "$STATE"
  echo "ok: reviewer pane closed"
}

case "${1:-}" in
  start)  shift; cmd_start "$@" ;;
  ask)    shift; cmd_ask "$@" ;;
  status) shift; cmd_status "$@" ;;
  close)  shift; cmd_close "$@" ;;
  *) die "usage: reviewer.sh {start|ask|status|close} ..." ;;
esac
