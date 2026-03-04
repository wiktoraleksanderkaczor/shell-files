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
