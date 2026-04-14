# Kiro CLI pre block. Keep at the top of this file.
[[ -f "${HOME}/Library/Application Support/kiro-cli/shell/zshrc.pre.zsh" ]] && builtin source "${HOME}/Library/Application Support/kiro-cli/shell/zshrc.pre.zsh"

# Install Oh My Zsh if missing
[[ ! -d "$HOME/.oh-my-zsh" ]] && sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

# Skip compaudit security checks - define as function to prevent autoload
function compaudit { return 0 }

# Stub compinit/compdef/bashcompinit/complete during load - we run them deferred
function compinit { : }
# function bashcompinit { : }
typeset -ga __compdef_args=()
function compdef { __compdef_args+=("$*") }
typeset -ga __complete_args=()
function complete { __complete_args+=("$*") }

# Plugin management — clone missing, update existing every 8h in background
() {
  local plugin_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins"
  local stamp="$HOME/.cache/zsh-plugin-update"
  local -A plugins=(
    colorize                 "https://github.com/zpm-zsh/colorize.git"
    colors                   "https://github.com/zpm-zsh/colors"
    fast-syntax-highlighting "https://github.com/zdharma-continuum/fast-syntax-highlighting.git"
    git-fuzzy                "https://github.com/bigH/git-fuzzy.git"
    warhol                   "https://github.com/unixorn/warhol.plugin.zsh.git"
    you-should-use           "https://github.com/MichaelAquilina/zsh-you-should-use.git"
    zsh-autosuggestions      "https://github.com/zsh-users/zsh-autosuggestions"
    zsh-completions          "https://github.com/zsh-users/zsh-completions.git"
    zsh-defer                "https://github.com/romkatv/zsh-defer.git"
    zsh-syntax-highlighting  "https://github.com/zsh-users/zsh-syntax-highlighting.git"
  )

  local do_update=false
  if [[ ! -f "$stamp" ]] || (( $(date +%s) - $(date -r "$stamp" +%s 2>/dev/null || echo 0) > 28800 )); then
    do_update=true
  fi

  local name url
  for name url in ${(kv)plugins}; do
    local dir="$plugin_dir/$name"
    if [[ ! -d "$dir/.git" ]]; then
      echo "zsh: cloning plugin $name..."
      git clone --depth=1 "$url" "$dir"
    elif $do_update; then
      ({
        local out; out=$(git -C "$dir" pull --ff-only 2>&1)
        [[ "$out" != *"Already up to date"* && -n "$out" ]] && echo "zsh: $name updated"
      } &!)
    fi
  done

  if $do_update; then
    echo "zsh: updating plugins due to 8 hour check..."
    touch "$stamp"
  fi
}

# Theme management — clone missing, update existing every 8h in background
() {
  local theme_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
  local stamp="$HOME/.cache/zsh-plugin-update"
  if [[ ! -d "$theme_dir/.git" ]]; then
    echo "zsh: cloning theme powerlevel10k..."
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$theme_dir"
  elif [[ -f "$stamp" ]] && (( $(date +%s) - $(date -r "$stamp" +%s 2>/dev/null || echo 0) <= 28800 )); then
    ({\
      local out; out=$(git -C "$theme_dir" pull --ff-only 2>&1)
      [[ "$out" != *"Already up to date"* && -n "$out" ]] && echo "zsh: powerlevel10k updated"
    } &!)
  fi
}

# Load helpers
source ~/shell-files/helpers.zsh
source ~/.oh-my-zsh/custom/plugins/zsh-defer/zsh-defer.plugin.zsh
source ~/shell-files/lazy-envs.zsh

# Compile .zshrc for faster loading
if [[ ~/.zshrc -nt ~/.zshrc.zwc ]]; then
  zcompile ~/.zshrc
fi

# Message of the day
motd() {
  emulate -L zsh
  local c=$'\e[36m' g=$'\e[32m' y=$'\e[33m' m=$'\e[35m' b=$'\e[1m' d=$'\e[2m' r=$'\e[0m'

  print -r -- \
    "${c}Shortcuts:${r} ${b}Ctrl-G${r} → fzf git files | ${b}Ctrl-R${r} → fzf history→prompt | ${b}Ctrl-T${r} → fzf insert paths"
  print -r -- \
    "          ${b}Opt-C${r} → fzf cd→dir | ${d}**<Tab>${r} → fzf insert files/dirs | ${b}Meta-K${r} → clear"
  print -r -- \
    "${c}Commands:${r} ${d}vcd${r} → cd to open VS Code workspace | ${d}realpath${r} → resolve full path"
  print -r -- \
    "${g}Difftastic:${r} ${d}difft-diff${r} | ${d}difft-show${r} | ${d}difft-log${r}"
  print -r -- \
    "${g}git-fuzzy:${r} ${d}git fuzzy${r} [status | branch | log | reflog | stash | diff | pr]"
  print -r -- \
    "${g}Dev:${r} ${d}lazygit${r} → TUI git | ${d}nnn${r} → file mgr | ${d}zellij${r} → terminal mux | ${d}btop${r} → system monitor"
  print -r -- \
    "${g}CLI:${r} ${d}jq${r}/${d}yq${r} → JSON/YAML | ${d}dust${r} → du | ${d}duf${r} → df | ${d}tldr${r} → man"
  print -r -- \
    "${y}fzf:${r} type → filter | ${b}Tab${r} → toggle multi-select"
  print -r -- \
    "${y}fzf extras:${r} ${d}fzf_git_show${r} → browse commits | ${d}fzf_man_search${r} → man pages | ${d}fzf_man_content_search${r}"
  print -r -- \
    "            ${d}export_aws_profile${r} → fzf select and export AWS_PROFILE"
  print -r -- \
    "${m}Fun:${r} ${d}matrix${r} | ${d}disappointed${r} | ${d}flip${r} | ${d}shrug${r}"
  print -r -- \
    "Run 'available --help' for more."
}

# Use Zellij
# source .zsh/zellij.zsh

if [[ -o interactive && -z "$MOTD_SHOWN" ]]; then
    export MOTD_SHOWN=1
    motd
fi

# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Enable Powerlevel10k instant prompt - allows typing while defers run in background
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Exports
export NVM_DIR="$HOME/.nvm"
export Q_AUTOSUGGEST_BUFFER_MAX_SIZE=20
export Q_AUTOSUGGEST_USE_ASYNC=true
export BUN_INSTALL="$HOME/Library/Application Support/reflex/bun"
export LDFLAGS="-L/opt/homebrew/opt/ruby@3.2/lib"
export CPPFLAGS="-I/opt/homebrew/opt/ruby@3.2/include"
export AWS_PAGER="cat"
export EDITOR=nano

# Hardmode use aliases
# export YSU_HARDCORE=1
unset YSU_HARDCORE

# PATH setup
path_prepend "$HOME/UluruMigrationCli"
path_prepend "$HOME/.toolbox/bin"
path_prepend "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/git-fuzzy/bin"
path_append "$HOME/.lmstudio/bin"
path_prepend "$BUN_INSTALL/bin"
path_prepend "$HOME/.rodar/bin" "/opt/homebrew/opt/ruby/bin"
# path_prepend "$HOME/.gem/ruby/3.4.0/bin"
path_prepend "/opt/homebrew/opt/ruby@3.2/bin"
path_prepend "$HOME/.lmstudio/bin"
path_prepend "$HOME/.local/bin"

# History setup
HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000000
SAVEHIST=10000000
setopt EXTENDED_HISTORY INC_APPEND_HISTORY SHARE_HISTORY HIST_REDUCE_BLANKS \
       HIST_IGNORE_DUPS HIST_IGNORE_ALL_DUPS HIST_FIND_NO_DUPS \
       HIST_IGNORE_SPACE HIST_SAVE_NO_DUPS

# Oh My Zsh configuration
export ZSH="$HOME/.oh-my-zsh"
DISABLE_AUTO_UPDATE="true"
DISABLE_MAGIC_FUNCTIONS="true"
DISABLE_COMPFIX="true"
COMPLETION_WAITING_DOTS="true"

if [[ "$TERM_PROGRAM" == "kiro" ]]; then
  # Leave empty
else
  # Your themes or customizations
  ZSH_THEME="powerlevel10k/powerlevel10k"
fi

plugins=(
  zsh-defer
  colors
  git
  brew
  macos
  docker
  aws
  node
  python
  vscode
  fast-syntax-highlighting
  zsh-autosuggestions
)
deferred_plugins=(colorize warhol you-should-use)
ZSH_COLORIZE_TOOL="pygmentize"
ZSH_COLORIZE_STYLE="colorful"
ZSH_HIGHLIGHT_HIGHLIGHTERS+=(brackets pattern cursor line regexp)
fpath=(~/.zfunc $fpath)
fpath+=${ZSH_CUSTOM:-${ZSH:-~/.oh-my-zsh}/custom}/plugins/zsh-completions/src

source $ZSH/oh-my-zsh.sh

source ~/shell-files/history.zsh

# Completion settings
setopt AUTO_MENU                 # Show completion menu on tab
setopt COMPLETE_IN_WORD          # Complete from both ends of word
setopt ALWAYS_TO_END             # Move cursor to end if word had one match
zstyle ':completion:*' menu select

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || zsource ~/.p10k.zsh

# Aliases
alias bb="brazil-build"
alias docker="finch"
alias cat='bat --plain --paging=never'
# alias find='fd'
# alias grep='rg'
# alias grep='git grep --exclude-standard'
alias du='dust'
alias df='duf'
alias watch='viddy'
alias moor='moar'
alias calc='kalker'
alias ps='procs'
alias tree='eza --tree --group-directories-first'
alias fm='nnn -dH'
alias ls='eza --group-directories-first'
alias la='eza -a --group-directories-first'
alias ll='eza -lag --group-directories-first --git'
alias clear="clear && printf '\e[3J'"
alias difft-diff='git -c diff.external=difft diff'
alias difft-show='git -c diff.external=difft show --ext-diff'
alias difft-log='git -c diff.external=difft log -p --ext-diff'
lt() {
  local d="${1:-$(read '?Depth (empty=all): ' d && echo $d)}"
  [[ -z "$d" ]] && eza --tree --group-directories-first || eza --tree --group-directories-first -L "$d"
}
docker_clean() {
  local ids=$(docker ps -aq | tr '\n' ' ')
  if [[ -z "$ids" ]]; then
    echo "No containers to remove"
  else
    echo "Removing containers:"
    docker rm -f ${=ids}
    echo "Done"
  fi
}

# Default file click open
# alias -s py=code

# Load functions
source ~/shell-files/file-functions.zsh
source ~/shell-files/auth-functions.zsh
source ~/shell-files/ai-functions.zsh
source ~/shell-files/fzf-functions.zsh

# Auto-activate venv when entering directory with .venv
autoload -U add-zsh-hook
_auto_venv() {
  if [[ -d .venv && -f .venv/bin/activate ]]; then
    [[ "$VIRTUAL_ENV" != "$PWD/.venv" ]] && source .venv/bin/activate
  elif [[ -n "$VIRTUAL_ENV" && "$VIRTUAL_ENV" == "$PWD/.venv" ]]; then
    deactivate 2>/dev/null
  fi
}
add-zsh-hook chpwd _auto_venv
_auto_venv  # Run on shell start

# Load deferred plugins (~55ms saved from sync startup)
for _p in $deferred_plugins; do
  local _ppath="$ZSH/custom/plugins/$_p/$_p.plugin.zsh"
  [[ ! -f "$_ppath" ]] && _ppath="$ZSH/plugins/$_p/$_p.plugin.zsh"
  [[ -f "$_ppath" ]] && zsh-defer source "$_ppath"
done
unset _p _ppath

# Deferred compinit - only rebuild if compdef calls changed
zsh-defer -c '
  local hash_file=~/.zcompdump.hash
  local new_hash=$(print -l "${__compdef_args[@]}" | md5)
  local old_hash=$(<$hash_file 2>/dev/null)
  # unfunction bashcompinit 2>/dev/null

  unfunction compinit compdef 2>/dev/null
  autoload -Uz compinit
  if [[ "$new_hash" != "$old_hash" ]]; then
    compinit
    print "$new_hash" > $hash_file
  else
    compinit -C
  fi
  unset __compdef_args
  # unfunction bashcompinit 2>/dev/null
  unfunction complete 2>/dev/null
  autoload -Uz bashcompinit && bashcompinit
  # Replay captured complete calls
  for c in "${__complete_args[@]}"; do complete ${=c}; done
  unset __complete_args
'

# Deferred recompile - run in background (only writes files, no shell state)
zsh-defer -c '
  {
    autoload -Uz zrecompile
    for f in ~/.oh-my-zsh/{plugins,custom/plugins}/*/*.plugin.zsh ~/.oh-my-zsh/lib/*.zsh; do
      [[ -f "$f" ]] && zrecompile -pq "$f"
    done
  } &!
'

# List explicitly installed utilities from package managers
available() {
  local filter="" full_aliases=false values_only=false strip_quotes=false
  for arg in "$@"; do
    case $arg in
      -h|--help) cat <<EOF
Usage: available [OPTIONS]

Options:
  --filter=SECTIONS   Show only specified sections (comma-separated)
                      Sections: aliases,functions,path
  --full-aliases      Show full alias definitions instead of just names
  --strip-quotes      Remove single quotes from alias definitions
  --values-only       Output only command names, sorted and unique
  -h, --help          Show this help

Examples:
  available                              Show all sections
  available --filter=aliases,path        Show only aliases and path
  available --full-aliases --strip-quotes Show full aliases without quotes
  available --values-only                List all commands for scripting
EOF
        return ;;
      --filter=*) filter="${arg#--filter=}" ;;
      --full-aliases) full_aliases=true ;;
      --strip-quotes) strip_quotes=true ;;
      --values-only) values_only=true ;;
    esac
  done
  local t=$(mktemp -d)
  _avail_section() { [[ -z $filter || $filter == *$1* ]]; }
  _avail_section aliases && { $full_aliases && { $strip_quotes && alias | sed "s/'//g" || alias } || alias | cut -d= -f1 } | sort > $t/1
  _avail_section functions && functions + | rg -Nv "^[_→+./-]" | rg -Nv "^[A-Z]" | rg -Nv "[()_-]$" | sort -u > $t/2
  _avail_section path && echo $PATH | tr ':' '\n' | while read d; do [[ -d $d ]] && /bin/ls "$d" 2>/dev/null; done | grep -v ' ' | sort -u > $t/3
  unfunction _avail_section
  if $values_only; then
    cat $t/{1,2,3} 2>/dev/null | sort -u
  else
    local names=(aliases functions path) i=1 first=true
    for f in $t/{1,2,3}; do
      [[ -s $f ]] && { $first || echo; first=false; echo "=== ${names[$i]} ==="; sed 's/^/- /' $f }
      ((i++))
    done
  fi
  rm -rf $t
}

# cd to VS Code workspace directory
vcd() {
  local dirs=(${(f)"$(lsof -c Code 2>/dev/null | awk '/cwd/ && $NF != "/" {print $NF}' | sort -u)"})
  (( ${#dirs} == 0 )) && { echo "No VS Code workspaces found"; return 1 }
  (( ${#dirs} == 1 )) && cd "${dirs[1]}" && return
  local sel=$(printf '%s\n' "${dirs[@]}" | fzf --height=40% --reverse --prompt="VS Code workspace: ")
  [[ -n "$sel" ]] && cd "$sel"
}

matrix() { echo -e "\e[1;40m" ; clear ; while :; do echo $LINES $COLUMNS $(( $RANDOM % $COLUMNS)) $(( $RANDOM % 72 )) ;sleep 0.05; done|awk '{ letters="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#$%^&*()"; c=$4;        letter=substr(letters,c,1);a[$3]=0;for (x in a) {o=a[x];a[x]=a[x]+1; printf "\033[%s;%sH\033[2;32m%s",o,x,letter; printf "\033[%s;%sH\033[1;37m%s\033[0;0H",a[x],x,letter;if (a[x] >= $1) { a[x]=0; } }}' }

disappointed() { echo -n " ಠ_ಠ " | tee /dev/tty | pbcopy; }

flip() { echo -n "（╯°□°）╯ ┻━┻" | tee /dev/tty | pbcopy; }

shrug() { echo -n "¯\_(ツ)_/¯" | tee /dev/tty | pbcopy; }

# Custom completions
source <(uluru --completion-init)

# Kiro CLI post block. Keep at the bottom of this file.
[[ -f "${HOME}/Library/Application Support/kiro-cli/shell/zshrc.post.zsh" ]] && builtin source "${HOME}/Library/Application Support/kiro-cli/shell/zshrc.post.zsh"
