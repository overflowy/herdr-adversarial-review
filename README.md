# Adversarial Review

A Claude Code skill that runs an adversarial code review using a **second, independent model** - GPT‑5.6 Sol - as the reviewer. Claude spawns the reviewer in a live [herdr](https://herdr.dev/) split pane, hands it your diff (or plan) plus the stated intent, waits for it to finish, then interrogates every finding against the actual code before relaying a verdict.

The reviewer runs interactively in its own pane, so you can watch it work or jump in and steer.

## How the pieces fit together

<img width="2120" height="1540" alt="ar" src="https://github.com/user-attachments/assets/c07dc5f9-262e-4843-ba13-2a95cd08656d" />

Four things need to be set up, in order: herdr, CLIProxyAPI, agent-safehouse, and the `safecodex` shell function. Then install the skill itself.

## 1. Install herdr

herdr is the agent multiplexer the skill drives - it creates the reviewer pane, sends it input, and waits on its idle/working/blocked status.

```bash
curl -fsSL https://herdr.dev/install.sh | sh
```

Run your terminal sessions inside herdr (see the [quick start](https://herdr.dev/docs/quick-start/)). The skill assumes the Claude Code session it runs in lives in a herdr pane, so it can split a sibling pane next to it.

## 2. Install and configure CLIProxyAPI

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) is a local proxy that exposes an Anthropic-compatible API backed by other providers' logins - here, an OpenAI/Codex login serving GPT‑5.6 Sol. This is what lets the stock `claude` CLI talk to a non-Anthropic model.

1. **Install** - download a binary from the [releases page](https://github.com/router-for-me/CLIProxyAPI/releases) (or use Docker; see the [guides](https://help.router-for.me/)).

2. **Create the config** at `~/.config/cli-proxy-api/config.yml`:

   ```yaml
   port: 8317
   auth-dir: "~/.cli-proxy-api"
   api-keys:
     - "<any-random-string>"   # e.g. output of: openssl rand -hex 24
   ```

   The API key is just a shared secret between the proxy and the `claude` CLI - make one up. Save it somewhere; the `safecodex` function needs it later.

3. **Log in with your OpenAI account** (Codex OAuth flow):

   ```bash
   cli-proxy-api --config ~/.config/cli-proxy-api/config.yml --codex-login
   ```

4. **Start the server** and leave it running:

   ```bash
   cli-proxy-api --config ~/.config/cli-proxy-api/config.yml
   ```

   The skill expects it on `http://localhost:8317`.

## 3. Install agent-safehouse

[agent-safehouse](https://agent-safehouse.dev/) provides macOS-native kernel-level sandboxing. The reviewer runs with `--dangerously-skip-permissions`, so the sandbox is what keeps it confined to the project directory - it can't touch your SSH keys, other repos, or anything outside its workspace.

```bash
brew install eugene1g/safehouse/agent-safehouse
```

Then add the `safe` wrapper to `~/.zshrc` (adjust for your shell):

```bash
safe() {
    safehouse --env --add-dirs="/tmp" "$@"
}
```

The `/tmp` grant matters for this skill: it's where the handoff files live (the skill writes the review prompt to `/tmp/adversarial-review/` and the reviewer writes its findings back there). Without it, the reviewer can't read its prompt or produce output.

## 4. Define the `safecodex` function

Add to `~/.zshrc` (adjust for your shell):

```bash
export CLI_PROXY_API_KEY="<the key from your config.yml>"

safecodex() {
    ANTHROPIC_BASE_URL=http://localhost:8317 \
        ANTHROPIC_AUTH_TOKEN="$CLI_PROXY_API_KEY" \
        ANTHROPIC_MODEL=gpt-5.6-sol \
        ANTHROPIC_SMALL_FAST_MODEL=gpt-5.6-sol \
        CLAUDE_CODE_SUBAGENT_MODEL=gpt-5.6-sol \
        CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1 \
        CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3 \
        ENABLE_TOOL_SEARCH=false \
        safe claude --model 'gpt-5.6-sol[1m]' --dangerously-skip-permissions "$@"
}
```

What each piece does:

- `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` - point the `claude` CLI at CLIProxyAPI with your shared key.
- `ANTHROPIC_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL` - route every model role to GPT‑5.6 Sol so nothing falls back to an Anthropic model the proxy can't serve.
- `--model 'gpt-5.6-sol[1m]'` - the `[1m]` suffix requests the 1M-token context window, so large diffs fit.
- `CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1` - exposes the effort setting for non-Anthropic models.
- `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3` / `ENABLE_TOOL_SEARCH=false` - tame concurrency and disable deferred-tool search, which the proxied model handles poorly.
- `safe … --dangerously-skip-permissions` - skip permission prompts, safely: the sandbox is the guardrail instead.

Reload your shell (`exec zsh`) and note that the function must be defined in your **interactive** shell config - the skill launches it via `herdr pane run`, which runs an interactive shell precisely so aliases and functions resolve.

## 5. Install the skill

The repo is a Claude Code plugin marketplace, so you can install it directly from within Claude Code:

```
/plugin marketplace add overflowy/herdr-claude-gpt-adversarial-review-skill
/plugin install adversarial-review@herdr-claude-gpt-adversarial-review-skill
```

Alternatively, copy the skill into your skills directory manually:

```bash
mkdir -p ~/.claude/skills/adversarial-review
cp skills/adversarial-review/SKILL.md ~/.claude/skills/adversarial-review/
```

## Usage

From a Claude Code session running inside a herdr pane, in the project you want reviewed:

```
/adversarial-review
```

or just ask in natural language - "poke holes in this diff", "red-team this plan", "get a second opinion before I ship". Claude will:

1. State the **intent** of the work (what the change is trying to achieve).
2. Write the diff + reviewer charge to a prompt file under `/tmp/adversarial-review/`.
3. Split a herdr pane and launch `safecodex` in it - the reviewer's TUI is live there.
4. Wait for the review to finish (herdr tracks the agent's status natively).
5. **Interrogate** every finding against the actual code, pressing the still-open reviewer session on anything disputed, and report each one as Confirmed, Disputed, or Unverified.

The last step matters: the reviewer is adversarial by instruction and will sometimes overstate or manufacture problems. You get verdicts, not raw output - and "nothing the reviewer found holds up" is a valid outcome.

## Smoke test

Before first use, verify each layer:

```bash
# Proxy is up and accepting your key
curl -s http://localhost:8317/v1/models -H "x-api-key: $CLI_PROXY_API_KEY"

# safecodex works end to end (one-shot, no TUI)
safecodex -p "Say ok"

# herdr can split and address panes (run inside herdr)
herdr pane split --current --direction right --ratio 0.4 --no-focus
```

## Troubleshooting

- **Reviewer pane opens but errors immediately** - usually the proxy: check it's running on 8317 and that `CLI_PROXY_API_KEY` matches an entry in `config.yml`'s `api-keys`.
- **Auth errors from the model** - the Codex OAuth token may have expired; re-run the `--codex-login` step.
- **`safecodex: command not found` in the pane** - the function isn't in your interactive shell config, or was only exported in one terminal. It must live in `~/.zshrc`.
- **Sandbox denials** - agent-safehouse grants read/write to the project directory only. If the review legitimately needs another path, add it to the `safe` wrapper's `--add-dirs` list.
