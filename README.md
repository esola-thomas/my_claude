# my_claude

Run [Claude Code](https://docs.claude.com/en/docs/claude-code) through a local [LiteLLM](https://github.com/BerriAI/litellm) proxy that is backed by your GitHub Copilot subscription.

`my_claude` does the setup that is easy to get wrong by hand:

- starts (or reuses) a LiteLLM proxy on `127.0.0.1`, with a key generated for your install
- asks Copilot which models your account has enabled, and writes the LiteLLM routes and the Claude Code model settings from that list
- exports the environment Claude Code needs, then starts `claude` with your arguments
- gives you `doctor`, `status`, `login`, and `stop` commands

## Read this first

- **This is an unofficial integration.** It is not affiliated with or endorsed by Anthropic, GitHub, Microsoft, or BerriAI.
- It uses **your own** Copilot subscription and **undocumented** Copilot endpoints. The model-discovery request sends client headers copied from VS Code Copilot Chat (`Editor-Version: vscode/1.95.0`, `User-Agent: GitHubCopilotChat/0.26.7`). That may conflict with the GitHub Copilot terms or your organization's policy, and it may stop working at any time. You are responsible for checking that your use is allowed.
- Claude Code is installed separately under Anthropic's terms and is not included here. LiteLLM is downloaded from PyPI under its own license.
- Prompts go to GitHub Copilot's service, not directly to Anthropic.

## Requirements

- Linux, bash 4.4 or newer, `curl`, `flock` (util-linux)
- [Claude Code](https://docs.claude.com/en/docs/claude-code/setup) on your PATH
- [uv](https://docs.astral.sh/uv/getting-started/installation/), which downloads Python 3.12 for you if needed
- A GitHub account with a Copilot seat that has Claude models enabled
- About 500 MB of disk for the Python environment

## Install

```bash
git clone https://github.com/esola-thomas/my_claude.git
cd my_claude
./install.sh
my_claude login      # one time: prints a code, you approve it in the browser
my_claude doctor
my_claude
```

Use `git clone`, not a zip download, so the executable bits are kept.

`install.sh` copies files under `~/.local` and runs `uv sync --locked` to build the environment. It needs no sudo. If `~/.local/bin` is not on your PATH it prints the line to add. Options: `--prefix DIR`, `--no-deps` (skip the Python environment; run `my_claude install-deps` later).

## Use

```bash
my_claude                          # interactive Claude Code
my_claude -p "explain this repo"   # one-shot
my_claude --dashboard              # also start the local dashboard
my_claude --model gpt-sol-latest  # any claude option works
my_claude -- --resume              # everything after -- goes to claude unchanged
```

Options before the claude arguments:

| Option | Effect |
|---|---|
| `--dashboard` | start the dashboard and print its URL |
| `--all-mcps` | ignore `mcp.json` and use every configured MCP server |
| `--no-sync` | skip model discovery, use the last generated config |
| `--` | pass the rest to claude as is |

Commands: `login [--force]`, `install-deps`, `doctor`, `status`, `stop`, `stop-all`, `version`.

## Models

Each launch discovers the newest enabled model per family and generates the routes. Claude Opus, Sonnet and Haiku are required. GPT Astra, Sol and Luna are used when your account has them.

| Select with | Route |
|---|---|
| `opus` / `sonnet` / `haiku` (built in) | newest enabled Claude Opus, Sonnet, Haiku (`[1m]` profile when the window is 1M) |
| `--model gpt-astra-latest` | newest enabled GPT Astra (when your account has it) |
| `--model gpt-sol-latest` | newest enabled GPT Sol |
| `--model gpt-luna-latest` | newest enabled GPT Luna |

The GPT routes are also listed in the `/model` picker. Claude Code has no user-defined short aliases, so use the full route names above.

Set `MY_CLAUDE_PRIMARY=claude-opus-5.0` to pin the primary Opus model.

## Doctor

`my_claude doctor` prints `PASS`, `WARN` or `FAIL` per item and exits 1 on any `FAIL`. It checks:

- bash, curl, flock, `claude` (path and version, `--settings` support), uv
- LiteLLM importable in the environment
- state directory and key file permissions
- the Copilot token, and a live catalog request (`401` means log in again, `403` means no seat or blocked by your organization)
- that the proxy port is free or owned by this tool
- user `~/.claude/settings.json` model keys that could override the generated ones
- proxy variables that could capture loopback traffic, and duplicate `my_claude` copies on PATH

## Files and security

State lives in `~/.local/state/my_claude` (override with `MY_CLAUDE_HOME`), mode 700, created with `umask 077`:

| File | Purpose |
|---|---|
| `key` | random proxy key, generated on first run |
| `config.yaml`, `models.env`, `settings.json` | generated on every launch, do not edit |
| `mcp.json` | optional: if present, claude is started with `--strict-mcp-config` and only these servers |
| `proxy.pid`, `proxy.log`, `lock` | process bookkeeping |

- The proxy binds to `127.0.0.1` only and requires the key. The key is not written into `config.yaml` and is not exported to claude's child processes except as `ANTHROPIC_AUTH_TOKEN`, which Claude Code needs.
- Before trusting a port, the launcher checks the pid file, the process owner, and the command line. If something else holds the port, it stops with an error and sends nothing to it. It never kills a process it did not start.
- The Copilot login token is stored by LiteLLM in `~/.config/litellm/github_copilot` (override with `GITHUB_COPILOT_TOKEN_DIR`).
- The dashboard needs the key in the URL, and it shows no command lines or host names.
- `~/.claude/settings.json` is never modified. Generated settings are passed with `--settings`.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `MY_CLAUDE_HOME` | `~/.local/state/my_claude` | state directory |
| `MY_CLAUDE_PORT` | `4141` | proxy port (dashboard uses port + 1) |
| `MY_CLAUDE_BIN` | `claude` from PATH | claude binary to run |
| `MY_CLAUDE_PRIMARY` | newest Opus | pin the primary Opus model id |
| `MY_CLAUDE_DASHBOARD` | `0` | `1` always starts the dashboard |
| `MY_CLAUDE_KEEP_STDIN` | `0` | `1` keeps piped stdin for `-p` runs |
| `GITHUB_COPILOT_TOKEN_DIR` | `~/.config/litellm/github_copilot` | where the Copilot token lives |

When you run `-p` with piped stdin, the launcher redirects stdin from `/dev/null` by default, as Claude Code can otherwise wait on it. Set `MY_CLAUDE_KEEP_STDIN=1` to pass your piped text through.

## Troubleshooting

- `command not found: my_claude`: add `~/.local/bin` to PATH, open a new shell, or run `hash -r`.
- An old copy or a shell function named `my_claude` runs instead: check with `type -a my_claude`. `doctor` warns about this.
- `port 4141 is in use`: set `MY_CLAUDE_PORT` to a free port.
- `HTTP 403` from the catalog: your account has no Copilot seat, or your organization blocks it.
- `uv sync failed`: check network access, any PyPI mirror, and `UV_PYTHON_DOWNLOADS`. On shared home directories set `UV_CACHE_DIR` and `MY_CLAUDE_HOME` to local disk.
- Proxy will not start: see `~/.local/state/my_claude/proxy.log`.

## Uninstall

```bash
./uninstall.sh      # stops the proxy, removes installed files, keeps state and the Copilot token
```

## Changes from a plain shell function

If you came from a zsh function version: this is a standalone bash script, so it needs no rc edits. The dashboard and the daily `claude update` are off by default, MCP servers are not restricted unless `mcp.json` exists, and the proxy key is generated per install.

## Development

```bash
python3 tests/test_sync.py        # model selection and config generation
bash tests/smoke.sh               # launcher, with stub claude and stub proxy; no network
shellcheck -x bin/my_claude lib/doctor.sh install.sh uninstall.sh tests/smoke.sh tests/fakebin/claude tests/fakebin/uv
```

## License

MIT
