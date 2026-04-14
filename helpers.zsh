# Helper to compile and source files for speed (from the "Speed Matters" blog post)
zsource() {
  local file=$1
  [[ ! -f "$file" ]] && return
  local zwc="${file}.zwc"
  # Compile if zwc doesn't exist or is older than the source file
  if [[ ! -f "$zwc" || "$file" -nt "$zwc" ]]; then
    zcompile "$file" 2>/dev/null
  fi
  source "$file"
}

path_prepend() {
  typeset -g PATH
  local dir
  for dir in "$@"; do
    [[ -z "$dir" ]] && continue
    if [[ -z "$PATH" ]]; then
      PATH="$dir"
    else
      PATH="$dir:$PATH"
    fi
  done
}

path_append() {
  typeset -g PATH
  local dir
  for dir in "$@"; do
    [[ -z "$dir" ]] && continue
    if [[ -z "$PATH" ]]; then
      PATH="$dir"
    else
      PATH="$PATH:$dir"
    fi
  done
}

# Auto-install missing brew dependencies in background
brew_ensure() {
  local -A cmd_formula=(
    eza eza bat bat dust dust duf duf viddy viddy
    moar moor kalker kalker procs procs nnn nnn fzf fzf
    difft difftastic lazygit lazygit zellij zellij btop btop
    jq jq yq yq tldr tldr pygmentize pygments rg ripgrep
    sqlite3 sqlite shfmt shfmt python3 python@3.14
  )
  local missing=()
  local cmd formula
  for cmd formula in ${(kv)cmd_formula}; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$formula")
  done
  (( ${#missing} == 0 )) && return
  # Deduplicate
  local -U uniq_missing=("${missing[@]}")
  echo "zsh: brew installing missing tools: ${uniq_missing[*]}"
  brew install "${uniq_missing[@]}"
}
