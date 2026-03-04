## Integrating Ranked History (history.zsh)

SQLite-backed scored history replacement for zsh. Replaces built-in history with
composite-scored suggestions, fzf search, sequence prediction, and cross-terminal sync.

### 1. Install dependencies

```bash
brew install fzf ripgrep sqlite3
brew install bat shfmt  # optional: used in Ctrl-R preview for syntax highlighting/formatting
```

### 2. Install zsh-defer

```bash
git clone https://github.com/romkatv/zsh-defer.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-defer
```

### 3. Install zsh-autosuggestions

```bash
git clone https://github.com/zsh-users/zsh-autosuggestions.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
```

### 4. Place the file

```bash
mkdir -p ~/.zsh
# Copy history.zsh to ~/.zsh/history.zsh
```

### 5. Update .zshrc

Source `zsh-defer` and `zsh-autosuggestions` before `history.zsh`. Order matters.

```zsh
# zsh-defer — must load before history.zsh
source ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-defer/zsh-defer.plugin.zsh

# zsh-autosuggestions — must load before history.zsh
source ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh

# Ranked History
source ~/.zsh/history.zsh
```

If using Oh My Zsh's `plugins=()` array, add `zsh-defer` and `zsh-autosuggestions`
there instead and source `history.zsh` after `source $ZSH/oh-my-zsh.sh`.

### 6. What history.zsh overrides

On load, it takes full ownership of history by setting:

```zsh
HISTFILE=/dev/null
SAVEHIST=0
HISTSIZE=100000
setopt NO_SHARE_HISTORY NO_INC_APPEND_HISTORY NO_EXTENDED_HISTORY \
       NO_HIST_SAVE_BY_COPY NO_APPEND_HISTORY
```

Any `HISTFILE`, `SAVEHIST`, or `setopt` history configuration in `.zshrc` is intentionally
nullified. All persistence moves to `~/.zsh_history_ranked.db` (SQLite, WAL mode, `chmod 600`).

### 7. Import existing history

```bash
# Start a new shell (auto-creates the DB), then:
_ranked_hist_import                # reads ~/.zsh_history by default
_ranked_hist_import ~/other_file   # or specify files explicitly
```

Parses standard zsh extended history format (`: timestamp:duration;command`), handles
multi-line commands, and splits compound commands (`&&`, `||`, `;`) into searchable fragments.

### 8. Keybindings

- `Ctrl-R` — fzf scored search with preview. `Ctrl-S` cycles modes (fuzzy/exact/regex/full), `Ctrl-X` deletes entry, `Ctrl-/` toggles preview.
- `Ctrl-T` — fzf file picker (inserts paths into buffer)
- `Alt-C` — fzf cd to selected directory
- `Opt+Up` / `Opt+Down` — global recency navigation across all history
- `Up` / `Down` — prefix-filtered search through zsh ring

These override fzf's default keybindings if fzf's `key-bindings.zsh` is also sourced.
Load `history.zsh` after fzf's script, or remove fzf's keybinding source entirely.

### 9. Verify

```bash
# Check DB exists and has data
sqlite3 ~/.zsh_history_ranked.db "SELECT count(*) FROM commands"

# Test Ctrl-R opens fzf with scored results
# Test typing a few characters shows autosuggest from ranked history
```
