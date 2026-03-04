fzf-modified-files() {
  local -a files
  local rec xy x y label display insert to from
  local arrow=' -> '
  local tmp out

  tmp=$(mktemp -t fzf-modified.XXXXXX) || return

  {
    git status --porcelain=v1 -z 2>/dev/null |
    {
      while IFS= read -r -d $'\0' rec; do
        [[ -z $rec ]] && continue

        xy=${rec[1,2]}
        x=${xy[1]}
        y=${xy[2]}

        if   [[ $xy == '??'            ]]; then label='[untracked]'
        elif [[ $x == D || $y == D     ]]; then label='[deleted]'
        elif [[ $x == A                ]]; then label='[added]'
        elif [[ $x == R                ]]; then label='[renamed]'
        elif [[ $x == C                ]]; then label='[copied]'
        elif [[ $x != ' ' && $y != ' ' ]]; then label='[staged+unstaged]'
        elif [[ $x != ' '              ]]; then label='[staged]'
        elif [[ $y != ' '              ]]; then label='[unstaged]'
        else                                label='[modified]'
        fi

        to=${rec[4,-1]}  # "XY<space><path>"

        if [[ $x == R || $x == C ]]; then
          IFS= read -r -d $'\0' from || break
          display="${from}${arrow}${to}"
          insert=$to
        else
          display=$to
          insert=$to
        fi

        printf '%s\t%s\t%s\0' "$label" "$display" "$insert"
      done
    } >| "$tmp" || return

    # Ensure the line editor is refreshed before launching full-screen UI
    zle -I

    out=$(
      command fzf --multi --read0 --print0 \
        --delimiter=$'\t' \
        --with-nth=1,2 \
        --accept-nth=3 \
        --tabstop=4 \
        < "$tmp"
    ) || return

    [[ -z $out ]] && { zle reset-prompt; return }

    while IFS= read -r -d $'\0' insert; do
      files+=("$insert")
    done <<< "$out"

    LBUFFER+="${(j: :)${(q)files[@]}} "
    zle reset-prompt
  } always {
    rm -f -- "$tmp"
  }
}

zle -N fzf-modified-files
bindkey '^g' fzf-modified-files

function fzf_git_show() {
  git log --graph --color=always \
      --format="%C(auto)%h%d %s %C(black)%C(bold)%cr" "$@" \
  | fzf --ansi --preview "echo {} \
    | grep -o '[a-f0-9]\{7\}' \
    | head -1 \
    | xargs -I % sh -c 'git show --color=always %'" \
        --bind "enter:execute:
            (grep -o '[a-f0-9]\{7\}' \
                | head -1 \
                | xargs -I % sh -c 'git show --color=always % \
                | less -R') << 'FZF-EOF'
            {}
FZF-EOF"
}


function  fzf_man_search(){
    man -k . \
    | fzf -n1,2 --preview "echo {} \
    | cut -d' ' -f1 \
    | sed 's# (#.#' \
    | sed 's#)##' \
    | xargs -I% man %" --bind "enter:execute: \
      (echo {} \
      | cut -d' ' -f1 \
      | sed 's# (#.#' \
      | sed 's#)##' \
      | xargs -I% man % \
      | less -R)"
}

function fzf_man_content_search(){
    local do_sort=0
    while [[ "$1" == -* ]]; do
        case "$1" in
            -h|--help) echo "Usage: fzf_man_content_search [-s] [query]\nSearch man page content with ripgrep, browse with fzf\n  -s  Sort by match count (disables streaming)"; return;;
            -s) do_sort=1; shift;;
            *) shift;;
        esac
    done
    local query="${1:-}"
    [[ -z "$query" ]] && read -r "query?Search man pages for: "
    [[ -z "$query" ]] && return 1
    if (( do_sort )); then
        rg -c --search-zip "$query" $(manpath | tr ':' ' ') 2>/dev/null \
        | sed 's|.*/||; s/\.[0-9a-z].*:/:/' \
        | awk -F: '!seen[$1]++ {printf "%4d %s\n", $2, $1}' \
        | sort -rn \
        | fzf -n2 --preview "man {2}" --bind "enter:execute:man {2} | less -R"
    else
        rg -c --search-zip "$query" $(manpath | tr ':' ' ') 2>/dev/null \
        | sed 's|.*/||; s/\.[0-9a-z].*:/:/' \
        | awk -F: '!seen[$1]++ {printf "%4d %s\n", $2, $1}' \
        | fzf -n2 --preview "man {2}" --bind "enter:execute:man {2} | less -R"
    fi
}

function export_aws_profile() {
  local profile=$( (echo $'\e[33mdefault\e[0m'; grep profile ${HOME}/.aws/config | awk '{print $2}' | sed 's,],,g') \
    | fzf --ansi --layout reverse --height=10% --border)
  [[ "$profile" == $'\e[33mdefault\e[0m' ]] && unset AWS_PROFILE || export AWS_PROFILE=$profile
}

viewlogs() {
  local session_dir="$HOME/.zsh_sessions"
  local logs=("$session_dir"/cmd_p*.yml(NomN))
  [[ ${#logs} -eq 0 ]] && { echo "No logs found."; return 1 }
  
  local selected=$(printf '%s\n' "${logs[@]:t}" | fzf \
    --header "Select Log | Enter: pbcopy contents" \
    --preview "[[ -f $session_dir/{} ]] && cat $session_dir/{}" \
    --layout=reverse --border)

  if [[ -n "$selected" ]]; then
    cat "$session_dir/$selected" | pbcopy
    echo "📋 Copied contents of $selected to clipboard."
  fi
}

searchlogs() {
  local session_dir="$HOME/.zsh_sessions"
  
  # Search for text, then show the file in fzf
  rg --ignore-case --files-with-matches "$1" "$session_dir"/cmd_pane*.txt | \
    xargs ls -t | \
    fzf --header "Search Results: $1" \
        --preview "grep --color=always -C 5 '$1' {}" \
        --bind "enter:execute(less {})"
}
