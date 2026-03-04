# Lazy environment loader with zsh-defer and synchronous fallback
typeset -g __lazy_envs_fully_loaded=false

__force_lazy_env_load() {
  [[ "$__lazy_envs_fully_loaded" == true ]] && return
  zsh-defer -t 0  # Flush all pending defers synchronously
  __lazy_envs_fully_loaded=true
}

command_not_found_handler() {
  local command="$1"
  shift

  # Force all deferred loads to complete
  __force_lazy_env_load
  hash -r

  # Check if command exists now
  if command -v "$command" >/dev/null 2>&1; then
    "$command" "$@"
    return $?
  fi

  print -u2 "zsh: command not found: $command"
  return 127
}

sudo() {
  emulate -L zsh
  local -a original=("$@")
  local -a opts=()
  local -a rest=()
  local seen_dd=false
  local expect_value=0
  local cmd=""
  local arg

  while (( $# > 0 )); do
    arg="$1"
    shift
    if [[ "$seen_dd" == false ]]; then
      if (( expect_value )); then
        opts+=("$arg")
        expect_value=0
        continue
      fi
      case "$arg" in
        --)
          opts+=("$arg")
          seen_dd=true
          continue
          ;;
        -C|-a|-c|-p|-r|-t|-u|-g)
          opts+=("$arg")
          expect_value=1
          continue
          ;;
        -C*|-a*|-c*|-p*|-r*|-t*|-u*|-g*)
          opts+=("$arg")
          continue
          ;;
        -*)
          opts+=("$arg")
          continue
          ;;
      esac
    fi
    cmd="$arg"
    rest=("$@")
    break
  done

  if [[ -z "$cmd" ]]; then
    command sudo "${original[@]}"
    return $?
  fi

  local resolved="$cmd"
  if [[ "$cmd" != */* ]]; then
    __force_lazy_env_load
    hash -r
    local candidate
    candidate=$(command -v "$cmd" 2>/dev/null)
    if [[ -n "$candidate" ]]; then
      resolved="$candidate"
    fi
  fi

  command sudo "${opts[@]}" "$resolved" "${rest[@]}"
}

# NVM
# OPTIMIZATION: Set PATH to default node immediately (sync), defer full nvm load
# - Original: sourced nvm.sh directly (1.33s) - nvm_auto does version detection
# - Now: PATH set in ~0ms, `node` works immediately
# - Impact: `nvm use` won't work until defer runs; node/.nvmrc auto-switch disabled
# - If you need .nvmrc support, the deferred _load_nvm will enable it
#
# Original code:
# _load_nvm() {
#   [[ -s "$NVM_DIR/nvm.sh" ]] || return 1
#   \. "$NVM_DIR/nvm.sh"
#   [[ -s "$NVM_DIR/bash_completion" ]] && \. "$NVM_DIR/bash_completion"
# }
export NVM_DIR="$HOME/.nvm"
if [[ -d "$NVM_DIR/versions/node" ]]; then
  local default_node=$(cat "$NVM_DIR/alias/default" 2>/dev/null)
  [[ "$default_node" == "lts/*" ]] && default_node=$(ls "$NVM_DIR/versions/node" | sort -V | tail -1)
  [[ -d "$NVM_DIR/versions/node/$default_node" ]] && path=("$NVM_DIR/versions/node/$default_node/bin" $path)
fi
_load_nvm() {
  [[ -s "$NVM_DIR/nvm.sh" ]] || return 1
  \. "$NVM_DIR/nvm.sh" --no-use  # --no-use skips slow nvm_auto version detection
  [[ -s "$NVM_DIR/bash_completion" ]] && \. "$NVM_DIR/bash_completion"
}

# Brazil
# OPTIMIZATION: Source completion script directly, skip slow wrapper (0.65s -> 0.1s)
# - Original: wrapper does `which brazil`, parses JSON to find completion script
# - Now: glob directly to latest brazilcli version's completion script
# - Impact: If brazilcli updates, glob finds new version automatically
#
# Original code:
# _load_brazil_completion() {
#   [[ -f /Users/wikkaczo/.brazil_completion/zsh_completion ]] || return 1
#   zsource /Users/wikkaczo/.brazil_completion/zsh_completion
# }
_load_brazil_completion() {
  local brazil_comp
  # Try direct path first (fast), fall back to wrapper (slow but always works)
  for brazil_comp in \
    ~/.toolbox/tools/brazilcli/*/bin/brazil_completion.zsh(N[-1]) \
    ~/.brazil_completion/zsh_completion; do
    [[ -f "$brazil_comp" ]] && { zsource "$brazil_comp"; return 0; }
  done
  return 1
}

# Isengard
_load_isengard() {
  if [[ -f ~/.isengard_completion.zsh ]]; then
    zsource ~/.isengard_completion.zsh
    return 0
  fi
  command -v isengardcli >/dev/null 2>&1 || return 1
  eval "$(isengardcli shell-autocomplete)"
}

# VS Code integration
# if [[ "$TERM_PROGRAM" == "vscode" ]]; then
#   if [[ -z "$VSCODE_SHELL_INTEGRATION_PATH" ]]; then
#     export VSCODE_SHELL_INTEGRATION_PATH="/Applications/Visual Studio Code.app/Contents/Resources/app/out/vs/workbench/contrib/terminal/common/scripts/shellIntegration-rc.zsh"
#   fi
#   [[ -f "$VSCODE_SHELL_INTEGRATION_PATH" ]] && zsh-defer zsource "$VSCODE_SHELL_INTEGRATION_PATH"
# fi

# Homebrew - set directly instead of slow `brew shellenv` (saves 105ms)
# Old code (skipped if HOMEBREW_PREFIX set):
# if [[ -z "$HOMEBREW_PREFIX" ]]; then
#   if [[ -f ~/.brew_shellenv ]]; then
#     zsh-defer zsource ~/.brew_shellenv
#   else
#     zsh-defer eval "$(/opt/homebrew/bin/brew shellenv)"
#   fi
# fi
export HOMEBREW_PREFIX="/opt/homebrew"
export HOMEBREW_CELLAR="/opt/homebrew/Cellar"
export HOMEBREW_REPOSITORY="/opt/homebrew"
path=("/opt/homebrew/bin" "/opt/homebrew/sbin" $path)

# Deferred loads
# NVM - fully lazy, only load when nvm command is used (saves 58ms)
nvm() { unfunction nvm; _load_nvm; nvm "$@" }
zsh-defer _load_brazil_completion
zsh-defer _load_isengard
zsh-defer -c '__lazy_envs_fully_loaded=true'
