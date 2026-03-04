repomix-tmp() {
    rm -f -- repomix-output.xml && repomix && fpbcopy repomix-output.xml
}

gemini-steering() {
  local config="$HOME/.gemini/settings.json"
  local steering_dir="$HOME/.kiro/steering"
  
  local files_json=$(ls "$steering_dir"/*.md 2>/dev/null | xargs -n 1 basename | jq -R . | jq -s .)

  if command -v jq >/dev/null 2>&1; then
    if [[ ! -f "$config" ]]; then 
      echo "{}" > "$config"
    fi

    jq --arg dir "$steering_dir" --argjson new_files "$files_json" \
      '.context.includeDirectories = ((.context.includeDirectories // []) + [$dir] | unique) |
      .context.loadMemoryFromIncludeDirectories = true |
      .context.fileName = (
        (if .context.fileName == null then ["GEMINI.md"] 
         elif (.context.fileName | type) == "string" then [.context.fileName] 
         else .context.fileName end) 
        + $new_files | unique
      )' "$config" > "$config.tmp" && mv "$config.tmp" "$config"
  fi

  command gemini "$@"
}

kiro-steering() {
  kiro-cli chat "$@"
}
