# ~/.zsh

Modular zsh configuration for macOS. Oh My Zsh + Powerlevel10k base with deferred loading, SQLite-backed ranked history, and fzf-driven workflows.

## Files

| File | Purpose |
|---|---|
| `.zshrc` | Entry point — plugins, aliases, PATH, completion, deferred init |
| `history.zsh` | SQLite-backed scored history: recording, autosuggest, Ctrl-R search, sequence prediction, import/export, weight tuning |
| `helpers.zsh` | `zsource` (compile-then-source), `path_prepend`, `path_append` |
| `lazy-envs.zsh` | Deferred environment loading (NVM, Homebrew, Brazil, Isengard) with `command_not_found_handler` fallback and `sudo` wrapper |
| `fzf-functions.zsh` | fzf utilities — git modified files (`Ctrl-G`), git log browser, man page search, AWS profile selector, session log viewer |
| `file-functions.zsh` | `fpbcopy` — copy file reference to macOS clipboard |
| `ai-functions.zsh` | CLI wrappers: `repomix-tmp`, `gemini-steering`, `kiro-steering` |
| `RANKED-HISTORY-INTEGRATION.md` | Setup guide for `history.zsh` |

## Dependencies

```bash
brew install fzf ripgrep sqlite3
brew install bat shfmt          # optional: Ctrl-R preview formatting
brew install eza dust duf procs viddy kalker  # aliased replacements
```

Plugins (Oh My Zsh custom):
- [zsh-defer](https://github.com/romkatv/zsh-defer) — deferred sourcing
- [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) — inline suggestions
- [fast-syntax-highlighting](https://github.com/zdharma-continuum/fast-syntax-highlighting)
- [zsh-completions](https://github.com/zsh-users/zsh-completions)
- [git-fuzzy](https://github.com/bigH/git-fuzzy)
- [you-should-use](https://github.com/MichaelAquilina/zsh-you-should-use) (deferred)
- [warhol](https://github.com/unixorn/warhol.plugin.zsh) (deferred)

## Startup Flow

1. `helpers.zsh` and `zsh-defer` load synchronously
2. `lazy-envs.zsh` sets Homebrew/NVM PATH immediately, defers full init
3. Oh My Zsh loads with plugin list
4. `history.zsh` takes ownership of history — sets `HISTFILE=/dev/null`, populates ring from SQLite, defers bucket loading
5. Remaining function files sourced
6. Deferred plugins, `compinit`, and recompilation run in background

## Keybindings

| Key | Action |
|---|---|
| `Ctrl-R` | fzf scored history search (modes: fuzzy/exact/regex/full) |
| `Ctrl-T` | fzf file picker → insert paths |
| `Ctrl-G` | fzf git modified files → insert paths |
| `Alt-C` | fzf directory picker → cd |
| `Opt+Up/Down` | Global recency navigation (all history) |
| `Up/Down` | Prefix-filtered ring search |

## Ranked History

SQLite database at `~/.zsh_history_ranked.db`. Composite scoring: recency (0.4) + directory affinity (0.35) + frequency (0.25), with fragment penalty, length penalty, path-existence boost, sibling-directory bonus, and sequence prediction.

Key commands:
- `_ranked_hist_import` — import from `~/.zsh_history`
- `_ranked_hist_export` — export to zsh extended history format
- `_ranked_hist_tune` — grid-search optimal weights from suggestion acceptance data
- `_ranked_hist_refresh` — reload in-memory buckets

See `RANKED-HISTORY-INTEGRATION.md` for full setup.

## Aliases

Modern CLI replacements:

- `cat` → `bat`
- `ls`/`ll`/`la` → `eza`
- `du` → `dust`
- `df` → `duf`
- `ps` → `procs`
- `watch` → `viddy`
- `grep` → `git grep`
- `docker` → `finch`
- `tree` → `eza --tree`

Run `available` for a full list of aliases, functions, and PATH commands. `available --help` for options.
