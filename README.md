# Polish — a lightweight AI-first shell

Polish is a minimal, fast alternative to oh-my-zsh built for the AI-coding
era. It gives you one shell setup that natively integrates the coding agents
you already use — Claude Code, Muse Code, Codex, OpenCode, and pi.dev —
with token-usage insights in your prompt, sane window/pane switching, and a
clean theme. No framework bloat: static plugin bundle, deferred loading,
`compinit` exactly once.

**Status:** early scaffold. `polish doctor` works today; agent plugins, the
token poller, and multiplexer helpers are landing incrementally.

## Why not oh-my-zsh?

oh-my-zsh loads hundreds of plugins and themes synchronously at startup
(typically 200–500ms with a modest plugin set). Polish instead composes:

- [Antidote](https://getantidote.github.io/) — static Zsh bundle
  (~50–80ms startup, OMZ-plugin compatible, `kind:defer` lazy loading)
- [Starship](https://starship.rs/) — cross-shell Rust prompt
  (~2–20ms renders, one TOML config)
- Cherry-picked OMZ plugins (`git`, `extract`, `tmux`) — no fork required
- `fnm` instead of eager `nvm` for fast Node switching

## Quickstart

```sh
curl -fsSL https://nitishagar.github.io/polish/install.sh | bash
# or, from a clone:
./installer/install.sh --shell zsh
exec zsh
polish doctor
```

Requires: `zsh`, `git`, `curl`. Optional: `starship`, `antidote`, `fnm`,
`tmux`, and any of `claude`, `muse`, `codex`, `opencode`, `pi`.

## What you get

| Area | What Polish does |
| --- | --- |
| Agents | Detects installed CLIs, unified `polish agents` status, per-agent session helpers |
| Tokens | Background poller aggregates per-CLI usage into `~/.usage/`; prompt shows day cost + context % |
| Windows | tmux autostart/aliases plus native Alt-hjkl switching (zellij/wezterm native configs) |
| Theme | Starship preset with AI modules (tokens, context, agent) |

Docs: <https://nitishagar.github.io/polish/> (`docs/` in this repo).

## Layout

- `init.zsh` — loader (antidote bundle, plugins, starship, compinit once)
- `.zsh_plugins.txt` — antidote bundle list
- `starship.toml` — prompt preset
- `bin/polish` — CLI (`doctor`, `agents`, `tokens`, `mux`, `theme`)
- `bin/polish-tokens-collect` — background usage poller (writes `~/.usage/`)
- `plugins/` — `polish-ai`, `polish-tokens`, `polish-mux` zsh plugins
- `installer/install.sh` — installer (`--shell/--from/--prefix/--uninstall`)
- `docs/` — static GitHub Pages site + install script
- `tests/run.sh` — test runner (no dependencies)

## License

MIT — see [LICENSE](LICENSE). (Apache-2.0 was considered for its patent
grant; MIT was chosen to match the zsh-like ask and house style.)
