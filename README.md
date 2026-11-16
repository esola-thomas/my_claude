# my_claude

Run [Claude Code](https://docs.claude.com/en/docs/claude-code) with a chosen knowledge pack loaded into its system prompt.

A pack is a markdown file. Put what you want Claude to treat as authoritative in it (a tool's commands, a codebase's conventions, a house style), then launch with `my_claude -a <pack>`.

## Requirements

- Linux, bash 4.4 or newer
- Claude Code installed and logged in (`claude` on your PATH)

## Install

```bash
git clone https://github.com/esola-thomas/my_claude.git
cd my_claude
./install.sh
```

Use `git clone`, not a zip download, so the executable bits are kept.

`install.sh` copies the launcher to `~/.local/bin`, copies the example packs to `~/.config/my_claude/` (existing files are never overwritten), and runs `my_claude doctor`. If `~/.local/bin` is not on your PATH it prints the line to add. It needs no sudo and no network.

Options: `--prefix DIR`, `--no-agents`, `--symlink` (link to the checkout, for development).

You can also run it straight from the clone without installing: `./bin/my_claude doctor`.

## Use

```bash
my_claude                          # interactive session with the default pack
my_claude -a your-docs-mcp-expert  # pick a pack
my_claude -p "How do I add a doc category?"   # one-shot answer
echo "question" | my_claude -p     # prompt from stdin
my_claude -a example -- --model opus          # options after -- go to claude unchanged
```

| Command | What it does |
|---|---|
| `my_claude doctor` | Check the setup and report PASS / WARN / FAIL per item |
| `my_claude doctor --probe` | Also make one small API call to confirm a pack reaches the model |
| `my_claude list` | List packs |
| `my_claude show NAME` | Print a pack |
| `my_claude new NAME` | Create a pack from the template |
| `my_claude init` | Copy the shipped packs into your config directory |

The default pack is `$MY_CLAUDE_DEFAULT_AGENT`, else `example`, else the first pack found. The launcher prints the pack path it loaded on stderr.

## Doctor

`my_claude doctor` checks:

- OS and bash version
- `claude` on PATH, runnable, and supporting `--append-system-prompt-file`
- Login state (`claude auth status`, or API/cloud credentials in the environment)
- That `my_claude` is on PATH, and how many copies are found
- The config directory, each pack (non-empty, titled, under the size limit), and the default pack
- Optional extras for shipped packs (for example `your-docs-mcp`)

It exits 1 if anything FAILs. Warnings do not change the exit code.

## Writing a pack

```bash
my_claude new myteam
$EDITOR ~/.config/my_claude/myteam.md
my_claude -a myteam
```

Start the file with `# Title`. Keep it under about 100 KB (warning) and under 1 MB (hard limit).

**Privacy:** the pack is sent to Anthropic as part of the system prompt, like any other prompt text. Do not put secrets in it.

## Shipped packs

- `example`: a template to copy.
- `your-docs-mcp-expert`: knowledge about [your-docs-mcp](https://github.com/esola-thomas/your-docs-mcp). Optional: `pip install your-docs-mcp` to run that server.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `MY_CLAUDE_CONFIG_DIR` | `${XDG_CONFIG_HOME:-~/.config}/my_claude` | Where packs live |
| `MY_CLAUDE_DEFAULT_AGENT` | `example` | Pack used when `-a` is not given |

## Troubleshooting

- `command not found: my_claude`: add `~/.local/bin` to PATH (install.sh prints the line), then open a new shell or run `hash -r`.
- An old copy runs instead of the new one: `doctor` lists every copy on PATH and the first one wins. A shell alias or function named `my_claude` also takes priority; check with `type -a my_claude`.
- `doctor` says not logged in: run `claude` once and complete login.

## Uninstall

```bash
./uninstall.sh          # removes the installed files; your packs are kept
```

## Development

```bash
bash tests/smoke.sh     # uses a stub claude, no network
shellcheck -x bin/my_claude lib/my_claude/doctor.sh install.sh uninstall.sh tests/smoke.sh tests/fakebin/claude
```

## License

MIT
