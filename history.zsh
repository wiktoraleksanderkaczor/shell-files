# Ranked History — SQLite-backed scored history for zsh
# Replaces history.zsh. Owns: recording, ring, suggestions, Ctrl-R, Ctrl-T, Alt-C, Opt+Up/Down.

zmodload zsh/datetime
zmodload zsh/stat

# --- Configuration (override before sourcing to customize) ---
: ${RANKED_HIST_W_RECENCY:=0.4}
: ${RANKED_HIST_W_PWD:=0.35}
: ${RANKED_HIST_W_FREQ:=0.25}
: ${RANKED_HIST_RING_SIZE:=10000}
: ${RANKED_HIST_DB:=$HOME/.zsh_history_ranked.db}
: ${ZSH_HISTORY_ARCHIVE:=$HOME/.zsh_history.archive_multiline}
: ${RANKED_HIST_FRAGMENT_PENALTY:=0.5}
: ${RANKED_HIST_LENGTH_THRESHOLD:=80}
: ${RANKED_HIST_LCP_MATCHES:=10}
: ${RANKED_HIST_LCP_MIN_VARIANTS:=3}
: ${RANKED_HIST_W_SEQUENCE:=0.4}
: ${RANKED_HIST_DIR_DEPTH_DECAY:=0.05}
: ${RANKED_HIST_PATH_EXISTS:=1.5}
: ${RANKED_HIST_EXPAND_ALIASES:=false}
: ${RANKED_HIST_SEQ_DIR_BONUS:=0.6}
: ${RANKED_HIST_SIBLING_FACTOR:=0.3}
: ${RANKED_HIST_LOG_SUGGESTIONS:=true}
: ${RANKED_HIST_USE_TUNED_WEIGHTS:=false}

# --- Global state ---
typeset -gA _RANKED_HIST_BUCKETS=()
typeset -ga _RANKED_HIST_GLOBAL_LIST=()
typeset -gi _RANKED_HIST_GLOBAL_IDX=0
typeset -g _RANKED_HIST_LAST_NAV_BUFFER=""
typeset -g _RANKED_HIST_SAVED_BUFFER=""
typeset -gi _RANKED_HIST_SAVED_CURSOR=0
# Record Separator — encodes newlines in commands for line-based bucket storage and sqlite3 output
typeset -g _RANKED_HIST_RS=$'\x1e'
# Unit Separator — field delimiter for multi-column sqlite3 query results (preview metadata)
typeset -g _RANKED_HIST_US=$'\x1f'
# Newline via variable — $'\n' literals don't work in the replacement part of ${var//pat/rep}
typeset -g _RANKED_HIST_NL=$'\n'
typeset -g _pending_cmd=""
typeset -g _cmd_start_time=""
typeset -g _RANKED_HIST_LAST_CMD=""
typeset -g _RANKED_HIST_PREV_CMD=""
typeset -g _RANKED_HIST_NEXT_PREDICTION=""
typeset -gi _RANKED_HIST_NEXT_PRED_COUNT=0
typeset -gA _RANKED_HIST_PATH_CACHE=()
typeset -g _RANKED_HIST_LAST_SUGGESTION=""
typeset -g _RANKED_HIST_LAST_PREFIX=""

# --- Override .zshrc history config ---
HISTFILE=/dev/null
SAVEHIST=0
HISTSIZE=100000
setopt NO_SHARE_HISTORY NO_INC_APPEND_HISTORY NO_EXTENDED_HISTORY NO_HIST_SAVE_BY_COPY NO_APPEND_HISTORY

# --- Task 1: SQL helper, schema, and fragment splitting ---

# Parameterized query helper. Template uses %s for string params (auto-quoted/escaped).
# Numeric values (timestamps) are interpolated directly in the template.
# Uses .timeout (dot-command) instead of PRAGMA busy_timeout to avoid output leaking into results.
_ranked_hist_sql() {
  local db="$RANKED_HIST_DB" q="'"
  local -a parts=("${(@s/%s/)1}")
  shift
  local sql="" part
  for part in "${parts[@]}"; do
    sql+="$part"
    if (( $# > 0 )); then
      sql+="'${1//$q/$q$q}'"
      shift
    fi
  done
  sqlite3 -escape off -cmd ".timeout 1000" "$db" "$sql" 2>/dev/null
}

_ranked_hist_init_db() {
  sqlite3 -cmd ".timeout 1000" "$RANKED_HIST_DB" "
    PRAGMA journal_mode=WAL;
    CREATE TABLE IF NOT EXISTS commands (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      cmd           TEXT    UNIQUE NOT NULL,
      total_count   INTEGER DEFAULT 1,
      last_used_ts  REAL    NOT NULL,
      first_used_ts REAL    NOT NULL,
      is_fragment   INTEGER DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS command_dirs (
      cmd_id              INTEGER NOT NULL,
      dir                 TEXT    NOT NULL,
      dir_count           INTEGER DEFAULT 1,
      last_used_in_dir_ts REAL    NOT NULL,
      UNIQUE(cmd_id, dir),
      FOREIGN KEY(cmd_id) REFERENCES commands(id)
    );
    CREATE INDEX IF NOT EXISTS idx_commands_last_used ON commands(last_used_ts DESC);
  " >/dev/null 2>/dev/null
  chmod 600 "$RANKED_HIST_DB" 2>/dev/null

  # Migrations
  local v=$(sqlite3 -cmd ".timeout 1000" "$RANKED_HIST_DB" "PRAGMA user_version" 2>/dev/null)
  if (( v < 2 )); then
    sqlite3 -cmd ".timeout 1000" "$RANKED_HIST_DB" "
      CREATE TABLE IF NOT EXISTS command_sequences (
        prev_cmd_id  INTEGER NOT NULL,
        next_cmd_id  INTEGER NOT NULL,
        count        INTEGER DEFAULT 1,
        last_seen_ts REAL    NOT NULL,
        UNIQUE(prev_cmd_id, next_cmd_id),
        FOREIGN KEY(prev_cmd_id) REFERENCES commands(id),
        FOREIGN KEY(next_cmd_id) REFERENCES commands(id)
      );
      CREATE INDEX IF NOT EXISTS idx_seq_prev ON command_sequences(prev_cmd_id);
      PRAGMA user_version = 2;" >/dev/null 2>/dev/null
  fi
  if (( v < 3 )); then
    sqlite3 -cmd ".timeout 1000" "$RANKED_HIST_DB" "
      CREATE INDEX IF NOT EXISTS idx_command_dirs_dir ON command_dirs(dir);
      PRAGMA user_version = 3;" >/dev/null 2>/dev/null
  fi
  if (( v < 4 )); then
    sqlite3 -cmd ".timeout 1000" "$RANKED_HIST_DB" "
      CREATE TABLE IF NOT EXISTS command_sequences_new (
        prev_cmd_id  INTEGER NOT NULL,
        next_cmd_id  INTEGER NOT NULL,
        dir          TEXT,
        count        INTEGER DEFAULT 1,
        last_seen_ts REAL    NOT NULL,
        UNIQUE(prev_cmd_id, next_cmd_id, dir),
        FOREIGN KEY(prev_cmd_id) REFERENCES commands(id),
        FOREIGN KEY(next_cmd_id) REFERENCES commands(id)
      );
      INSERT OR IGNORE INTO command_sequences_new
        SELECT prev_cmd_id, next_cmd_id, NULL, count, last_seen_ts FROM command_sequences;
      DROP TABLE IF EXISTS command_sequences;
      ALTER TABLE command_sequences_new RENAME TO command_sequences;
      CREATE INDEX IF NOT EXISTS idx_seq_prev ON command_sequences(prev_cmd_id);
      PRAGMA user_version = 4;" >/dev/null 2>/dev/null
  fi
  if (( v < 5 )); then
    sqlite3 -cmd ".timeout 1000" "$RANKED_HIST_DB" "
      CREATE TABLE IF NOT EXISTS suggestion_log (
        ts         REAL    NOT NULL,
        prefix     TEXT    NOT NULL,
        suggestion TEXT    NOT NULL,
        executed   TEXT    NOT NULL,
        accepted   INTEGER NOT NULL,
        dir        TEXT
      );
      CREATE TABLE IF NOT EXISTS tuned_weights (
        id        INTEGER PRIMARY KEY CHECK(id = 1),
        w_recency REAL NOT NULL,
        w_pwd     REAL NOT NULL,
        w_freq    REAL NOT NULL,
        acceptance_rate REAL,
        sample_size     INTEGER,
        tuned_at        REAL
      );
      PRAGMA user_version = 5;" >/dev/null 2>/dev/null
  fi
}

# Builds a SQL IN-list of PWD and all its parent directories (index-friendly).
# Sets REPLY to e.g. '/Users/foo/bar','/Users/foo','/Users','/'
_ranked_hist_pwd_in_list() {
  local q="'" dir="$PWD"
  REPLY="'${PWD//$q/$q$q}'"
  while [[ "$dir" == */* && "$dir" != "/" ]]; do
    dir="${dir%/*}"
    [[ -z "$dir" ]] && dir="/"
    REPLY+=",'${dir//$q/$q$q}'"
  done
}

# Runs the scored query — outputs RS-encoded commands to stdout, one per line, highest score first.
_ranked_hist_scored_query() {
  local now=$EPOCHREALTIME q="'"
  local select="replace(c.cmd, char(10), char(30))"
  [[ "$1" == "with-id" ]] && select="c.id || char(9) || $select"
  _ranked_hist_pwd_in_list
  local pwd_in="$REPLY"
  # Sibling dir matching: parent of PWD, escaped for LIKE
  local parent_pwd="${PWD%/*}"
  [[ -z "$parent_pwd" ]] && parent_pwd="/"
  local parent_esc="${parent_pwd//$q/$q$q}"
  local pwd_esc="${PWD//$q/$q$q}"
  sqlite3 -escape off -cmd ".timeout 1000" "$RANKED_HIST_DB" "
    SELECT $select FROM commands c
    LEFT JOIN (
      SELECT cmd_id, MAX(
        (1.0 / (1.0 + ($now - last_used_in_dir_ts) / 86400.0))
        * (1.0 / (1.0 + (${#PWD} - length(dir)) * $RANKED_HIST_DIR_DEPTH_DECAY))
      ) AS pwd_score
      FROM command_dirs WHERE dir IN ($pwd_in)
      GROUP BY cmd_id
    ) pwd ON pwd.cmd_id = c.id
    LEFT JOIN (
      SELECT cmd_id, MAX(
        1.0 / (1.0 + ($now - last_used_in_dir_ts) / 86400.0)
      ) AS sib_score
      FROM command_dirs
      WHERE dir LIKE '$parent_esc/%'
        AND dir NOT LIKE '$parent_esc/%/%'
        AND dir != '$pwd_esc'
      GROUP BY cmd_id
    ) sib ON sib.cmd_id = c.id
    ORDER BY (
      $RANKED_HIST_W_RECENCY * (1.0 / (1.0 + ($now - c.last_used_ts) / 86400.0))
      + $RANKED_HIST_W_PWD * (COALESCE(pwd.pwd_score, 0.0) + $RANKED_HIST_SIBLING_FACTOR * COALESCE(sib.sib_score, 0.0))
      + $RANKED_HIST_W_FREQ * (min(c.total_count, 100) / 100.0)
    ) * CASE WHEN c.is_fragment = 1 THEN $RANKED_HIST_FRAGMENT_PENALTY ELSE 1.0 END
      * (1.0 / (1.0 + max(length(c.cmd) - $RANKED_HIST_LENGTH_THRESHOLD, 0) / 200.0)) DESC" 2>/dev/null
}

# Splits a command on &&, ||, ; and returns fragment INSERT SQL via $REPLY.
# Args: $1=command, $2=timestamp (numeric, interpolated directly)
_ranked_hist_fragment_sql() {
  REPLY=""
  local q="'"
  local -a parts
  IFS=$'\n' parts=($(printf '%s' "$1" | LC_ALL=C sed 's/ *&& */\n/g; s/ *|| */\n/g; s/ *; */\n/g'))
  (( ${#parts} <= 1 )) && return
  local p=""
  for p in "${parts[@]}"; do
    p="${p## }"; p="${p%% }"
    [[ -z "$p" ]] && continue
    local esc="${p//$q/$q$q}"
    REPLY+="INSERT INTO commands(cmd, total_count, last_used_ts, first_used_ts, is_fragment) VALUES('$esc', 1, $2, $2, 1) ON CONFLICT(cmd) DO UPDATE SET total_count = total_count + 1, last_used_ts = $2;"
  done
}

_ranked_hist_rebuild_fragments() {
  local db="$RANKED_HIST_DB" q="'"
  sqlite3 -cmd ".timeout 1000" "$db" "
    DELETE FROM command_sequences WHERE prev_cmd_id IN (SELECT id FROM commands WHERE is_fragment = 1) OR next_cmd_id IN (SELECT id FROM commands WHERE is_fragment = 1);
    DELETE FROM command_dirs WHERE cmd_id IN (SELECT id FROM commands WHERE is_fragment = 1);
    DELETE FROM commands WHERE is_fragment = 1;"
  local n=0
  sqlite3 -cmd ".timeout 1000" -separator $'\x1f' "$db" \
    "SELECT cmd, total_count, last_used_ts, first_used_ts FROM commands
     WHERE cmd LIKE '%&&%' OR cmd LIKE '%||%' OR cmd LIKE '%;%'" 2>/dev/null \
  | while IFS=$'\x1f' read -r cmd cnt last_ts first_ts; do
    local -a parts
    IFS=$'\n' parts=($(printf '%s' "$cmd" | LC_ALL=C sed 's/ *&& */\n/g; s/ *|| */\n/g; s/ *; */\n/g'))
    (( ${#parts} <= 1 )) && continue
    local sql="" p=""
    for p in "${parts[@]}"; do
      p="${p## }"; p="${p%% }"
      [[ -z "$p" ]] && continue
      local esc="${p//$q/$q$q}"
      sql+="INSERT INTO commands(cmd, total_count, last_used_ts, first_used_ts, is_fragment)
        VALUES('$esc', $cnt, $last_ts, $first_ts, 1)
        ON CONFLICT(cmd) DO UPDATE SET
          total_count = total_count + $cnt,
          last_used_ts = MAX(last_used_ts, $last_ts),
          first_used_ts = MIN(first_used_ts, $first_ts)
        WHERE is_fragment = 1;"
    done
    [[ -n "$sql" ]] && sqlite3 -cmd ".timeout 1000" "$db" "$sql" 2>/dev/null
    (( n++ ))
  done
  echo "Fragments rebuilt from $n compound commands."
}

# --- Task 2: Command recording ---

# Save existing zshaddhistory if present (guard against double-sourcing)
if ! (( _RANKED_HIST_HOOK_INSTALLED )); then
  if (( ${+functions[zshaddhistory]} )); then
    functions[_ranked_hist_orig_zshaddhistory]="$functions[zshaddhistory]"
  fi
  typeset -gi _RANKED_HIST_HOOK_INSTALLED=1
fi

zshaddhistory() {
  typeset -g _pending_cmd="${1%%$'\n'}"
  typeset -g _cmd_start_time=$EPOCHREALTIME
  # Honor HIST_IGNORE_SPACE — skip ring for space-prefixed commands
  if [[ -o HIST_IGNORE_SPACE && "$1" == [[:space:]]* ]]; then
    :
  else
    print -s -- "${1%%$'\n'}"
  fi
  # Chain to previous definition for its side effects
  if (( ${+functions[_ranked_hist_orig_zshaddhistory]} )); then
    _ranked_hist_orig_zshaddhistory "$@"
  fi
  # Return 2: we own ring addition via print -s; prevent zsh double-add and HISTFILE write
  return 2
}

_RANKED_HIST_DB_MTIME=0

_ranked_hist_precmd() {
  local exit_code=$?
  
  # Cross-terminal sync: reload buckets if DB was modified externally
  local mtime
  zstat -A mtime +mtime "$RANKED_HIST_DB" 2>/dev/null
  if [[ "${mtime[1]}" != "$_RANKED_HIST_DB_MTIME" && -n "$_RANKED_HIST_DB_MTIME" && "$_RANKED_HIST_DB_MTIME" != "0" ]]; then
    _ranked_hist_load
  fi
  _RANKED_HIST_DB_MTIME="${mtime[1]}"

  # Log suggestion outcome (before _pending_cmd is cleared)
  if [[ "$RANKED_HIST_LOG_SUGGESTIONS" == true && -n "$_RANKED_HIST_LAST_SUGGESTION" ]]; then
    if [[ -n "$_pending_cmd" ]]; then
      local _sug="$_RANKED_HIST_LAST_SUGGESTION" _pfx="$_RANKED_HIST_LAST_PREFIX"
      local _exe="$_pending_cmd"
      # Normalize alias so executed form matches DB
      if [[ "$RANKED_HIST_EXPAND_ALIASES" == true ]]; then
        local _ef="${_exe%% *}"
        if (( ${+aliases[$_ef]} )) && [[ "${aliases[$_ef]%% *}" != "$_ef" ]]; then
          _exe="${aliases[$_ef]}${_exe#$_ef}"
        fi
      fi
      local _acc=0
      [[ "$_exe" == "$_sug"* || "$_sug" == "$_exe"* ]] && _acc=1
      { _ranked_hist_sql \
        "INSERT INTO suggestion_log(ts, prefix, suggestion, executed, accepted, dir)
         VALUES($EPOCHREALTIME, %s, %s, %s, $_acc, %s)" \
        "$_pfx" "$_sug" "$_exe" "$PWD" } &!
    fi
    _RANKED_HIST_LAST_SUGGESTION=""
  fi

  [[ -z "$_pending_cmd" ]] && return

  local duration_float=$(( EPOCHREALTIME - _cmd_start_time ))
  local duration_int=${duration_float%.*}
  local now=$EPOCHREALTIME
  local cmd="$_pending_cmd"

  # Clean up immediately
  _pending_cmd=""
  _cmd_start_time=""

  # Honor HIST_IGNORE_SPACE — skip DB write for space-prefixed commands
  [[ -o HIST_IGNORE_SPACE && "$cmd" == [[:space:]]* ]] && return

  # Expand first-word alias to canonical form (skip self-referencing, e.g. ls='ls --color')
  if [[ "$RANKED_HIST_EXPAND_ALIASES" == true ]]; then
    local _afirst="${cmd%% *}"
    if (( ${+aliases[$_afirst]} )) && [[ "${aliases[$_afirst]%% *}" != "$_afirst" ]]; then
      cmd="${aliases[$_afirst]}${cmd#$_afirst}"
    fi
  fi

  # Filter: only worthy commands go to DB
  # Success (0), Ctrl-C (130), or long-running non-not-found
  if [[ $exit_code -eq 0 || $exit_code -eq 130 || ($duration_int -ge 1 && $exit_code -ne 127) ]]; then
    # Async DB write
    {
      # Build fragment SQL for compound commands
      _ranked_hist_fragment_sql "$cmd" "$now"
      local seq_sql=""
      local -a seq_params=()
      if [[ -n "$_RANKED_HIST_LAST_CMD" ]]; then
        seq_sql="INSERT INTO command_sequences(prev_cmd_id, next_cmd_id, dir, count, last_seen_ts)
          SELECT (SELECT id FROM commands WHERE cmd = %s),
                 (SELECT id FROM commands WHERE cmd = %s), %s, 1, $now
          WHERE (SELECT id FROM commands WHERE cmd = %s) IS NOT NULL
          ON CONFLICT(prev_cmd_id, next_cmd_id, dir) DO UPDATE SET
            count = count + 1, last_seen_ts = $now;"
        seq_params=("$_RANKED_HIST_LAST_CMD" "$cmd" "$PWD" "$_RANKED_HIST_LAST_CMD")
      fi
      _ranked_hist_sql \
        "BEGIN;
         INSERT INTO commands(cmd, total_count, last_used_ts, first_used_ts)
           VALUES(%s, 1, $now, $now)
           ON CONFLICT(cmd) DO UPDATE SET
             total_count = total_count + 1, last_used_ts = $now, is_fragment = 0;
         INSERT INTO command_dirs(cmd_id, dir, dir_count, last_used_in_dir_ts)
           VALUES((SELECT id FROM commands WHERE cmd = %s), %s, 1, $now)
           ON CONFLICT(cmd_id, dir) DO UPDATE SET
             dir_count = dir_count + 1, last_used_in_dir_ts = $now;
         $REPLY
         ${seq_sql:+$seq_sql}
         COMMIT;" \
        "$cmd" "$cmd" "$PWD" \
        "${seq_params[@]}"
    } &!

    # Cache sequence prediction for empty-buffer suggestion
    _RANKED_HIST_NEXT_PREDICTION=""
    _RANKED_HIST_NEXT_PRED_COUNT=0
    local pred
    pred=$(_ranked_hist_sql \
      "SELECT replace(c.cmd, char(10), char(30)) || char(31) || s1.total
       FROM (
         SELECT next_cmd_id, SUM(count) AS total,
           SUM(count) * (1.0 - $RANKED_HIST_SEQ_DIR_BONUS)
           + SUM(CASE WHEN dir = %s THEN count ELSE 0 END) * $RANKED_HIST_SEQ_DIR_BONUS AS score
         FROM command_sequences
         WHERE prev_cmd_id = (SELECT id FROM commands WHERE cmd = %s)
         GROUP BY next_cmd_id
       ) s1
       JOIN commands c ON c.id = s1.next_cmd_id
       LEFT JOIN (
         SELECT next_cmd_id,
           SUM(count) * (1.0 - $RANKED_HIST_SEQ_DIR_BONUS)
           + SUM(CASE WHEN dir = %s THEN count ELSE 0 END) * $RANKED_HIST_SEQ_DIR_BONUS AS score
         FROM command_sequences
         WHERE prev_cmd_id = (SELECT id FROM commands WHERE cmd = %s)
         GROUP BY next_cmd_id
       ) s2 ON s2.next_cmd_id = s1.next_cmd_id
       WHERE c.is_fragment = 0
       ORDER BY s1.score + $RANKED_HIST_W_SEQUENCE * COALESCE(s2.score, 0) DESC
       LIMIT 1" \
      "$PWD" "$cmd" "$PWD" "$_RANKED_HIST_PREV_CMD")
    if [[ -n "$pred" ]]; then
      _RANKED_HIST_NEXT_PRED_COUNT="${pred##*$_RANKED_HIST_US}"
      _RANKED_HIST_NEXT_PREDICTION="${pred%$_RANKED_HIST_US*}"
      _RANKED_HIST_NEXT_PREDICTION="${_RANKED_HIST_NEXT_PREDICTION//$_RANKED_HIST_RS/$_RANKED_HIST_NL}"
    fi

    # Shift sequence tracking
    _RANKED_HIST_PREV_CMD="$_RANKED_HIST_LAST_CMD"
    _RANKED_HIST_LAST_CMD="$cmd"

    # Task 6: Incremental in-memory bucket update
    if (( ${#_RANKED_HIST_BUCKETS} )); then
      local encoded="${cmd//$'\n'/$_RANKED_HIST_RS}"
      local key2="${encoded[1,2]}" key1="${encoded[1]}"
      local bucket lines_str

      # Update 2-char bucket
      bucket="${_RANKED_HIST_BUCKETS[$key2]}"
      if [[ -n "$bucket" ]]; then
        local -a lines=("${(f)bucket}")
        lines=(${lines:#${(b)encoded}})
        _RANKED_HIST_BUCKETS[$key2]="$encoded"$'\n'"${(F)lines}"
      else
        _RANKED_HIST_BUCKETS[$key2]="$encoded"
      fi

      # Update 1-char bucket
      bucket="${_RANKED_HIST_BUCKETS[$key1]}"
      if [[ -n "$bucket" ]]; then
        local -a lines=("${(f)bucket}")
        lines=(${lines:#${(b)encoded}})
        _RANKED_HIST_BUCKETS[$key1]="$encoded"$'\n'"${(F)lines}"
      else
        _RANKED_HIST_BUCKETS[$key1]="$encoded"
      fi

      # Update global list — move to position 1
      local decoded="${encoded//$_RANKED_HIST_RS/$_RANKED_HIST_NL}"
      _RANKED_HIST_GLOBAL_LIST=(${_RANKED_HIST_GLOBAL_LIST:#${(b)decoded}})
      _RANKED_HIST_GLOBAL_LIST=("$decoded" "${_RANKED_HIST_GLOBAL_LIST[@]}")
    fi
  fi
}

# --- Task 3: Shell-start ring population ---

_ranked_hist_populate_ring() {
  sqlite3 -escape off -cmd ".timeout 1000" "$RANKED_HIST_DB" \
    "SELECT replace(cmd, char(10), char(30)) FROM commands
     ORDER BY last_used_ts ASC LIMIT $RANKED_HIST_RING_SIZE" 2>/dev/null \
  | while IFS= read -r line; do
      print -s -- "${line//$_RANKED_HIST_RS/$_RANKED_HIST_NL}"
    done
}

# --- Task 4: Scored query and in-memory loading ---

_ranked_hist_load() {
  _RANKED_HIST_BUCKETS=()
  _RANKED_HIST_GLOBAL_LIST=()

  # Buckets: ordered by composite score (for inline suggestions)
  local line
  local -A _alias_seen=()
  _ranked_hist_scored_query \
  | while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      # Normalize first-word aliases to canonical form; deduplicate
      if [[ "$RANKED_HIST_EXPAND_ALIASES" == true ]]; then
        local _af="${line%% *}"
        if (( ${+aliases[$_af]} )) && [[ "${aliases[$_af]%% *}" != "$_af" ]]; then
          line="${aliases[$_af]}${line#$_af}"
        fi
        if (( ${+_alias_seen[$line]} )); then continue; fi
        _alias_seen[$line]=1
      fi
      local key2="${line[1,2]}" key1="${line[1]}"
      # Dual-bucket: store in both 1-char and 2-char buckets
      if [[ -n "${_RANKED_HIST_BUCKETS[$key2]}" ]]; then
        _RANKED_HIST_BUCKETS[$key2]+=$'\n'"$line"
      else
        _RANKED_HIST_BUCKETS[$key2]="$line"
      fi
      if [[ -n "${_RANKED_HIST_BUCKETS[$key1]}" ]]; then
        _RANKED_HIST_BUCKETS[$key1]+=$'\n'"$line"
      else
        _RANKED_HIST_BUCKETS[$key1]="$line"
      fi
    done

  # Global list: ordered by pure recency (for Opt+Up/Down navigation)
  sqlite3 -escape off -cmd ".timeout 1000" "$RANKED_HIST_DB" \
    "SELECT replace(cmd, char(10), char(30)) FROM commands
     WHERE is_fragment = 0
     ORDER BY last_used_ts DESC" 2>/dev/null \
  | while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      _RANKED_HIST_GLOBAL_LIST+=("${line//$_RANKED_HIST_RS/$_RANKED_HIST_NL}")
    done
}

_ranked_hist_refresh() { _ranked_hist_load }

# Lightweight chpwd handler — rebuilds only score-ordered buckets (skips global list,
# which is recency-ordered and PWD-independent).
_ranked_hist_chpwd() {
  _RANKED_HIST_BUCKETS=()
  _RANKED_HIST_PATH_CACHE=()
  local line
  local -A _alias_seen=()
  _ranked_hist_scored_query \
  | while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "$RANKED_HIST_EXPAND_ALIASES" == true ]]; then
        local _af="${line%% *}"
        if (( ${+aliases[$_af]} )) && [[ "${aliases[$_af]%% *}" != "$_af" ]]; then
          line="${aliases[$_af]}${line#$_af}"
        fi
        if (( ${+_alias_seen[$line]} )); then continue; fi
        _alias_seen[$line]=1
      fi
      local key2="${line[1,2]}" key1="${line[1]}"
      if [[ -n "${_RANKED_HIST_BUCKETS[$key2]}" ]]; then
        _RANKED_HIST_BUCKETS[$key2]+=$'\n'"$line"
      else
        _RANKED_HIST_BUCKETS[$key2]="$line"
      fi
      if [[ -n "${_RANKED_HIST_BUCKETS[$key1]}" ]]; then
        _RANKED_HIST_BUCKETS[$key1]+=$'\n'"$line"
      else
        _RANKED_HIST_BUCKETS[$key1]="$line"
      fi
    done
}

# --- Task 5: Autosuggest strategy ---

# Returns 0 if the token is a flag or shell operator (not a path candidate).
_ranked_hist_is_skip_token() {
  case "$1" in
    -*|'|'*|'&&'|'||'|';'*|'>'*|'<'*|'('*|')'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Returns 0 if the token looks like a filesystem path:
#   contains /    →  src/main.py, ./script, /etc/hosts
#   starts with . →  .gitignore, ../dir
#   has extension →  file.txt, Makefile.bak
_ranked_hist_is_path_like() {
  case "$1" in
    */*|.*|*.[a-zA-Z]*) return 0 ;;
    *) return 1 ;;
  esac
}

_zsh_autosuggest_strategy_ranked_history() {
  _RANKED_HIST_LAST_SUGGESTION=""
  local prefix="$1"
  if [[ -z "$prefix" ]]; then
    if [[ -n "$_RANKED_HIST_NEXT_PREDICTION" ]]; then
      suggestion="$_RANKED_HIST_NEXT_PREDICTION"
      _RANKED_HIST_LAST_SUGGESTION="$suggestion"; _RANKED_HIST_LAST_PREFIX=""
    fi
    return
  fi
  # Expand first-word alias in prefix for canonical bucket lookup; track for reverse-map
  local _arev=""
  if [[ "$RANKED_HIST_EXPAND_ALIASES" == true ]]; then
    local _pf="${prefix%% *}"
    if (( ${+aliases[$_pf]} )) && [[ "${aliases[$_pf]%% *}" != "$_pf" ]]; then
      _arev="$_pf"
      prefix="${aliases[$_pf]}${prefix#$_pf}"
    fi
  fi
  # Promote sequence prediction when prefix matches and seen more than once
  if (( _RANKED_HIST_NEXT_PRED_COUNT > 1 )) && [[ -n "$_RANKED_HIST_NEXT_PREDICTION" && "$_RANKED_HIST_NEXT_PREDICTION" == "$prefix"* ]]; then
    suggestion="$_RANKED_HIST_NEXT_PREDICTION"
    _RANKED_HIST_LAST_SUGGESTION="$suggestion"; _RANKED_HIST_LAST_PREFIX="$1"
    [[ -n "$_arev" ]] && suggestion="${_arev}${suggestion#${aliases[$_arev]}}"
    return
  fi
  local key="${prefix[1,2]}"
  local bucket="${_RANKED_HIST_BUCKETS[$key]}"
  [[ -z "$bucket" ]] && { key="${prefix[1]}"; bucket="${_RANKED_HIST_BUCKETS[$key]}" }
  [[ -z "$bucket" ]] && return
  local encoded_prefix="${prefix//$'\n'/$_RANKED_HIST_RS}"

  # Collect top matches for divergence detection
  local -a matches=()
  local line
  while IFS= read -r line; do
    [[ "$line" == "$encoded_prefix"* ]] && {
      matches+=("$line")
      (( ${#matches} >= RANKED_HIST_LCP_MATCHES )) && break
    }
  done <<< "$bucket"

  (( ${#matches} == 0 )) && return

  if (( ${#matches} >= RANKED_HIST_LCP_MIN_VARIANTS )); then
    # Compute longest common prefix across top matches
    local lcp="${matches[1]}" m
    for m in "${matches[@]:1}"; do
      while [[ "${m[1,${#lcp}]}" != "$lcp" ]]; do
        lcp="${lcp[1,-2]}"
      done
    done
    # If divergence exists, truncate to word boundary
    if (( ${#lcp} < ${#matches[1]} )); then
      local trimmed="${lcp% }"
      if [[ "$trimmed" == *" "* ]]; then
        local truncated="${trimmed% *} "
        if (( ${#truncated} > ${#encoded_prefix} + 3 )); then
          suggestion="${truncated//$_RANKED_HIST_RS/$_RANKED_HIST_NL}"
          _RANKED_HIST_LAST_SUGGESTION="$suggestion"; _RANKED_HIST_LAST_PREFIX="$1"
          [[ -n "$_arev" ]] && suggestion="${_arev}${suggestion#${aliases[$_arev]}}"
          return
        fi
      fi
    fi
  fi

  # Path existence weighting: among top matches, boost those whose path-like
  # arguments exist relative to PWD. RANKED_HIST_PATH_EXISTS is a multiplier
  # on the rank score (0=disabled, 1.0=no effect, 1.5=default boost).
  local best="${matches[1]}"
  if (( RANKED_HIST_PATH_EXISTS )); then
    local best_score=0 candidate cmd token unquoted _ckey
    local i=0 n=${#matches}
    for candidate in "${matches[@]}"; do
      (( i++ ))
      local base_score=$(( n - i + 1 ))
      local has_path=0
      cmd="${candidate//$_RANKED_HIST_RS/$_RANKED_HIST_NL}"
      local -a tokens=(${(z)cmd})
      for token in "${tokens[@]:1}"; do
        _ranked_hist_is_skip_token "$token" && continue
        unquoted="${(Q)token}"
        _ckey="$PWD:$unquoted"
        if (( ${+_RANKED_HIST_PATH_CACHE[$_ckey]} )); then
          (( ${_RANKED_HIST_PATH_CACHE[$_ckey]} )) && { has_path=1; break }
          continue
        fi
        _RANKED_HIST_PATH_CACHE[$_ckey]=0
        if _ranked_hist_is_path_like "$unquoted" && [[ -e "$unquoted" ]]; then
          _RANKED_HIST_PATH_CACHE[$_ckey]=1
          has_path=1
          break
        fi
      done
      local score=$(( has_path ? base_score * RANKED_HIST_PATH_EXISTS : base_score ))
      if (( score > best_score )); then
        best_score=$score
        best="$candidate"
      fi
    done
  fi

  suggestion="${best//$_RANKED_HIST_RS/$_RANKED_HIST_NL}"
  _RANKED_HIST_LAST_SUGGESTION="$suggestion"; _RANKED_HIST_LAST_PREFIX="$1"
  [[ -n "$_arev" ]] && suggestion="${_arev}${suggestion#${aliases[$_arev]}}"
}

# --- Task 7: Ctrl-R replacement ---

_ranked_hist_preview() {
  local id="$1"
  [[ -z "$id" || "$id" == *[^0-9]* ]] && return
  zmodload zsh/datetime 2>/dev/null
  local db="${RANKED_HIST_DB:-$HOME/.zsh_history_ranked.db}"
  local now=${EPOCHREALTIME:-$(date +%s)}
  local q="'" pwd_esc="${PWD//$q/$q$q}"
  local parent_pwd="${PWD%/*}"
  [[ -z "$parent_pwd" ]] && parent_pwd="/"
  local parent_esc="${parent_pwd//$q/$q$q}"
  local meta
  meta=$(sqlite3 -escape off -cmd ".timeout 1000" -separator $_RANKED_HIST_US "$db" "
    SELECT replace(c.cmd, char(10), char(30)), c.total_count,
      datetime(c.last_used_ts, 'unixepoch', 'localtime'),
      datetime(c.first_used_ts, 'unixepoch', 'localtime'),
      c.is_fragment,
      round(${RANKED_HIST_W_RECENCY:-0.4} * (1.0 / (1.0 + ($now - c.last_used_ts) / 86400.0)), 4),
      round(${RANKED_HIST_W_PWD:-0.35} * COALESCE((
        SELECT MAX(
          (1.0 / (1.0 + ($now - cd2.last_used_in_dir_ts) / 86400.0))
          * (1.0 / (1.0 + (length('$pwd_esc') - length(cd2.dir)) * ${RANKED_HIST_DIR_DEPTH_DECAY:-0.05}))
        ) FROM command_dirs cd2
        WHERE cd2.cmd_id = c.id AND ('$pwd_esc' = cd2.dir OR '$pwd_esc' LIKE cd2.dir || '/%')
      ), 0.0), 4),
      round(${RANKED_HIST_W_FREQ:-0.25} * (min(c.total_count, 100) / 100.0), 4),
      CASE WHEN c.is_fragment = 1 THEN ${RANKED_HIST_FRAGMENT_PENALTY:-0.5} ELSE 1.0 END,
      round(1.0 / (1.0 + max(length(c.cmd) - ${RANKED_HIST_LENGTH_THRESHOLD:-80}, 0) / 200.0), 4),
      round(${RANKED_HIST_W_PWD:-0.35} * ${RANKED_HIST_SIBLING_FACTOR:-0.3} * COALESCE((
        SELECT MAX(1.0 / (1.0 + ($now - cd3.last_used_in_dir_ts) / 86400.0))
        FROM command_dirs cd3
        WHERE cd3.cmd_id = c.id
          AND cd3.dir LIKE '$parent_esc/%'
          AND cd3.dir NOT LIKE '$parent_esc/%/%'
          AND cd3.dir != '$pwd_esc'
      ), 0.0), 4)
    FROM commands c
    WHERE c.id = $id" 2>/dev/null)
  [[ -z "$meta" ]] && { echo "Command not found in DB"; return }
  local cmd count last_used first_used is_frag s_recency s_pwd s_freq s_frag_pen s_len_pen s_sibling
  IFS=$_RANKED_HIST_US read -r cmd count last_used first_used is_frag s_recency s_pwd s_freq s_frag_pen s_len_pen s_sibling <<< "$meta"
  cmd="${cmd//$_RANKED_HIST_RS/$_RANKED_HIST_NL}"
  local dirs
  dirs=$(sqlite3 -cmd ".timeout 1000" "$db" "
    SELECT '  ' || dir || ' (' || dir_count || 'x)'
    FROM command_dirs WHERE cmd_id = $id
    ORDER BY dir_count DESC LIMIT 5" 2>/dev/null)
  local _pe_found="" _pe_mult=1.0
  if (( ${RANKED_HIST_PATH_EXISTS:-1} )); then
    local _pe_token _pe_uq
    local -a _pe_tokens=(${(z)cmd})
    for _pe_token in "${_pe_tokens[@]:1}"; do
      case "$_pe_token" in
        -*|'|'*|'&&'|'||'|';'*|'>'*|'<'*|'('*|')'*) continue ;;
      esac
      _pe_uq="${(Q)_pe_token}"
      case "$_pe_uq" in
        */*|.*|*.[a-zA-Z]*) [[ -e "$_pe_uq" ]] && { _pe_found="$_pe_uq"; _pe_mult=${RANKED_HIST_PATH_EXISTS:-1.5}; break } ;;
      esac
    done
  fi
  local total_score
  total_score=$(printf '%.4f' "$(printf '%s\n' "$s_recency + $s_pwd + $s_sibling + $s_freq" | bc -l 2>/dev/null)")
  local effective_score
  effective_score=$(printf '%.4f' "$(printf '%s\n' "($s_recency + $s_pwd + $s_sibling + $s_freq) * $s_frag_pen * $s_len_pen * $_pe_mult" | bc -l 2>/dev/null)")
  printf '\033[1;36m── Command ──\033[0m\n'
  local formatted
  if command -v shfmt >/dev/null 2>&1; then
    formatted=$(printf '%s' "$cmd" | shfmt -ln bash 2>/dev/null) || formatted="$cmd"
  else
    formatted="$cmd"
  fi
  formatted=$(printf '%s' "$formatted" | awk '{
    line = $0; n = length(line); col = 0; iq = 0; qc = ""
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1)
      p = (i > 1) ? substr(line, i-1, 1) : ""
      if (!iq) { if (c == "\"" || c == "'\''") { iq = 1; qc = c } }
      else if (c == qc && !(qc == "\"" && p == "\\")) { iq = 0 }
      if (!iq && c == " " && i < n && substr(line, i+1, 1) == "-") {
        printf " \\\n  "; col = 2
      } else { printf "%s", c; col++ }
    }
    printf "\n"
  }')
  if command -v bat >/dev/null 2>&1; then
    printf '%s' "$formatted" | bat --language=zsh --style=plain --color=always --paging=never
  else
    printf '\033[1;33m%s\033[0m\n' "$formatted"
  fi
  printf '\n\n\033[1;36m── Metadata ──\033[0m\n'
  printf '\033[1m%-18s\033[0m %s\n' "Row ID:" "$id"
  printf '\033[1m%-18s\033[0m %s\n' "Times called:" "$count"
  printf '\033[1m%-18s\033[0m %s\n' "Last used:" "$last_used"
  printf '\033[1m%-18s\033[0m %s\n' "First used:" "$first_used"
  [[ "$is_frag" == "1" ]] && printf '\033[1m%-18s\033[0m \033[33myes\033[0m\n' "Fragment:"
  printf '\n\033[1;36m── Score ──\033[0m\n'
  printf '\033[1m%-18s\033[0m %s\n' "Recency:" "$s_recency"
  printf '\033[1m%-18s\033[0m %s\n' "PWD bonus:" "$s_pwd"
  printf '\033[1m%-18s\033[0m %s\n' "Sibling bonus:" "$s_sibling"
  printf '\033[1m%-18s\033[0m %s\n' "Frequency:" "$s_freq"
  printf '\033[1m%-18s\033[0m %s\n' "Subtotal:" "$total_score"
  printf '\033[1m%-18s\033[0m %s\n' "Fragment penalty:" "×$s_frag_pen"
  printf '\033[1m%-18s\033[0m %s\n' "Length penalty:" "×$s_len_pen"
  if [[ -n "$_pe_found" ]]; then
    printf '\033[1m%-18s\033[0m \033[32m×%s\033[0m (%s)\n' "Path exists:" "$_pe_mult" "$_pe_found"
  elif (( ${RANKED_HIST_PATH_EXISTS:-1} )); then
    printf '\033[1m%-18s\033[0m \033[2mno\033[0m\n' "Path exists:"
  fi
  printf '\033[1m%-18s\033[0m %s\n' "Effective:" "$effective_score"
  if [[ -n "$dirs" ]]; then
    printf '\n\033[1;36m── Top Directories ──\033[0m\n'
    printf '%s\n' "$dirs"
  fi
  local seqs
  seqs=$(sqlite3 -escape off -cmd ".timeout 1000" "$db" "
    SELECT '  → ' || c2.cmd || ' (' || cs.count || 'x)'
    FROM command_sequences cs
    JOIN commands c2 ON c2.id = cs.next_cmd_id
    WHERE cs.prev_cmd_id = $id AND c2.is_fragment = 0
    ORDER BY cs.count DESC LIMIT 3" 2>/dev/null)
  if [[ -n "$seqs" ]]; then
    printf '\n\033[1;36m── Usually Followed By ──\033[0m\n'
    printf '%s\n' "$seqs"
  else
    printf '\n\033[1;36m── Usually Followed By ──\033[0m\n'
    printf '  \033[2m(none yet)\033[0m\n'
  fi
  local prev_seqs
  prev_seqs=$(sqlite3 -escape off -cmd ".timeout 1000" "$db" "
    SELECT '  ← ' || c1.cmd || ' (' || cs.count || 'x)'
    FROM command_sequences cs
    JOIN commands c1 ON c1.id = cs.prev_cmd_id
    WHERE cs.next_cmd_id = $id AND c1.is_fragment = 0
    ORDER BY cs.count DESC LIMIT 3" 2>/dev/null)
  if [[ -n "$prev_seqs" ]]; then
    printf '\n\033[1;36m── Usually Preceded By ──\033[0m\n'
    printf '%s\n' "$prev_seqs"
  else
    printf '\n\033[1;36m── Usually Preceded By ──\033[0m\n'
    printf '  \033[2m(none yet)\033[0m\n'
  fi
}

_rh_search() {
  zmodload zsh/datetime 2>/dev/null
  eval "$_RH_BOOT"
  if [[ -z "$1" ]]; then
    _ranked_hist_scored_query with-id; return
  fi
  case "$FZF_PROMPT" in
    'EXACT> ') _ranked_hist_scored_query with-id | rg -iF -- "$1" || true ;;
    'REGEX> ') _ranked_hist_scored_query with-id | rg -i  -- "$1" 2>/dev/null || true ;;
    'FULL> ')  _ranked_hist_scored_query with-id | awk -F'\t' -v q="$1" 'BEGIN{q=tolower(q)} tolower($2)==q' || true ;;
    *)         _ranked_hist_scored_query with-id | fzf --filter "$1" --delimiter '\t' --nth 2.. --no-sort || true ;;
  esac
}

_rh_delete() {
  local id="$1"
  [[ "$id" == <-> ]] || return
  local meta
  meta=$(sqlite3 -cmd ".timeout 1000" -separator $'\x1f' "$RANKED_HIST_DB" \
    "SELECT cmd, total_count FROM commands WHERE id=$id" 2>/dev/null)
  [[ -z "$meta" ]] && return
  local cmd cnt q="'"
  IFS=$'\x1f' read -r cmd cnt <<< "$meta"
  local -a parts
  IFS=$'\n' parts=($(printf '%s' "$cmd" | LC_ALL=C sed 's/ *&& */\n/g; s/ *|| */\n/g; s/ *; */\n/g'))
  local sql=""
  if (( ${#parts} > 1 )); then
    local p=""
    for p in "${parts[@]}"; do
      p="${p## }"; p="${p%% }"
      [[ -z "$p" ]] && continue
      local esc="${p//$q/$q$q}"
      sql+="UPDATE commands SET total_count = total_count - $cnt WHERE cmd = '$esc' AND is_fragment = 1;"
    done
    sql+="DELETE FROM command_sequences WHERE prev_cmd_id IN (SELECT id FROM commands WHERE is_fragment = 1 AND total_count <= 0) OR next_cmd_id IN (SELECT id FROM commands WHERE is_fragment = 1 AND total_count <= 0);"
    sql+="DELETE FROM command_dirs WHERE cmd_id IN (SELECT id FROM commands WHERE is_fragment = 1 AND total_count <= 0);"
    sql+="DELETE FROM commands WHERE is_fragment = 1 AND total_count <= 0;"
  fi
  sql+="DELETE FROM command_sequences WHERE prev_cmd_id=$id OR next_cmd_id=$id;"
  sql+="DELETE FROM command_dirs WHERE cmd_id=$id;"
  sql+="DELETE FROM commands WHERE id=$id;"
  sqlite3 -cmd ".timeout 1000" "$RANKED_HIST_DB" "$sql"
}

_ranked_hist_search() {
  zle -I
  local output=$(
    export _RH_BOOT="$(functions _ranked_hist_scored_query _ranked_hist_pwd_in_list _ranked_hist_sql _rh_search _rh_delete)"
    export RANKED_HIST_PREVIEW="$(functions _ranked_hist_preview)"
    export RANKED_HIST_DB RANKED_HIST_W_RECENCY RANKED_HIST_W_PWD RANKED_HIST_W_FREQ
    export RANKED_HIST_W_SEQUENCE RANKED_HIST_FRAGMENT_PENALTY RANKED_HIST_LENGTH_THRESHOLD
    export RANKED_HIST_DIR_DEPTH_DECAY RANKED_HIST_PATH_EXISTS RANKED_HIST_SIBLING_FACTOR
    export _RANKED_HIST_RS _RANKED_HIST_US _RANKED_HIST_NL
    _ranked_hist_scored_query with-id \
    | fzf --disabled --delimiter='\t' --with-nth=2.. \
          --query="$BUFFER" --reverse --no-sort \
          --prompt='FUZZY> ' \
          --preview 'eval "$RANKED_HIST_PREVIEW"; _ranked_hist_preview {1}' \
          --preview-window='right:45%:wrap' \
          --header='Ranked History' \
          --footer='ctrl-s: mode | ctrl-x: delete | ctrl-/: preview' \
          --footer-border \
          --bind 'start:reload:eval "$_RH_BOOT"; _rh_search {q}' \
          --bind 'change:reload:eval "$_RH_BOOT"; _rh_search {q}' \
          --bind 'ctrl-x:execute-silent:eval "$_RH_BOOT"; _rh_delete {1}' \
          --bind 'ctrl-x:+reload:eval "$_RH_BOOT"; _rh_search {q}' \
          --bind 'ctrl-x:+print(DEL)' \
          --bind 'ctrl-/:toggle-preview' \
          --bind 'ctrl-s:transform:
              case $FZF_PROMPT in
                "FUZZY> ") echo "change-prompt(EXACT> )" ;;
                "EXACT> ") echo "change-prompt(REGEX> )" ;;
                "REGEX> ") echo "change-prompt(FULL> )"  ;;
                *)         echo "change-prompt(FUZZY> )" ;;
              esac' \
          --bind 'ctrl-s:+reload:eval "$_RH_BOOT"; _rh_search {q}'
  )

  local had_delete=0 selected=""
  while IFS= read -r line; do
    [[ "$line" == DEL ]] && had_delete=1 || selected="$line"
  done <<< "$output"

  if [[ -n "$selected" ]]; then
    local cmd="${selected#*	}"
    BUFFER="${cmd//$_RANKED_HIST_RS/$_RANKED_HIST_NL}"; CURSOR=${#BUFFER}
  fi
  (( had_delete )) && _ranked_hist_load
  zle reset-prompt
}
zle -N _ranked_hist_search
bindkey "^R" _ranked_hist_search

# --- Task 8: Opt+Up/Down global history navigation ---

_ranked_hist_global_up() {
  POSTDISPLAY=""
  # Auto-reset if buffer changed since last navigation
  [[ "$BUFFER" != "$_RANKED_HIST_LAST_NAV_BUFFER" ]] && _RANKED_HIST_GLOBAL_IDX=0
  if (( _RANKED_HIST_GLOBAL_IDX == 0 )); then
    _RANKED_HIST_SAVED_BUFFER="$BUFFER"
    _RANKED_HIST_SAVED_CURSOR="$CURSOR"
  fi
  # Scan forward for next entry matching saved prefix
  local prefix="$_RANKED_HIST_SAVED_BUFFER" i=$(( _RANKED_HIST_GLOBAL_IDX + 1 ))
  while (( i <= ${#_RANKED_HIST_GLOBAL_LIST} )); do
    local entry="${_RANKED_HIST_GLOBAL_LIST[$i]}"
    if [[ -z "$prefix" || "$entry" == "$prefix"* ]]; then
      _RANKED_HIST_GLOBAL_IDX=$i
      BUFFER="$entry"; CURSOR=${#BUFFER}
      _RANKED_HIST_LAST_NAV_BUFFER="$BUFFER"
      zle reset-prompt
      return
    fi
    (( i++ ))
  done
}

_ranked_hist_global_down() {
  POSTDISPLAY=""
  local prefix="$_RANKED_HIST_SAVED_BUFFER" i=$(( _RANKED_HIST_GLOBAL_IDX - 1 ))
  # Scan backward for previous entry matching saved prefix
  while (( i >= 1 )); do
    local entry="${_RANKED_HIST_GLOBAL_LIST[$i]}"
    if [[ -z "$prefix" || "$entry" == "$prefix"* ]]; then
      _RANKED_HIST_GLOBAL_IDX=$i
      BUFFER="$entry"; CURSOR=${#BUFFER}
      _RANKED_HIST_LAST_NAV_BUFFER="$BUFFER"
      zle reset-prompt
      return
    fi
    (( i-- ))
  done
  # No more matches — restore original buffer
  _RANKED_HIST_GLOBAL_IDX=0
  BUFFER="$_RANKED_HIST_SAVED_BUFFER"
  CURSOR="$_RANKED_HIST_SAVED_CURSOR"
  _RANKED_HIST_LAST_NAV_BUFFER=""
  zle reset-prompt
}

zle -N _ranked_hist_global_up
zle -N _ranked_hist_global_down
bindkey "^[[1;3A" _ranked_hist_global_up
bindkey "^[[1;3B" _ranked_hist_global_down

# Regular Up/Down: prefix-filtered search through zsh ring
bindkey "^[[A" history-beginning-search-backward
bindkey "^[[B" history-beginning-search-forward

# --- Task 9: Reimplement fzf keybindings (Ctrl-T, Alt-C) ---

_ranked_hist_file_widget() {
  zle -I
  local selected=$(
    fzf --multi --scheme=path \
      --walker=file,dir,follow,hidden \
      --walker-skip=.git,node_modules \
      --height=40% --reverse \
      --prompt="Files> "
  )
  [[ -n "$selected" ]] && LBUFFER+="${(q)${(f)selected}} "
  zle reset-prompt
}
zle -N _ranked_hist_file_widget
bindkey "^T" _ranked_hist_file_widget

_ranked_hist_cd_widget() {
  zle -I
  local selected=$(
    fzf --scheme=path \
      --walker=dir,follow,hidden \
      --walker-skip=.git,node_modules \
      --height=40% --reverse \
      --prompt="Cd> "
  )
  [[ -n "$selected" ]] && cd "$selected"
  zle reset-prompt
}
zle -N _ranked_hist_cd_widget
bindkey "^[c" _ranked_hist_cd_widget

_ranked_hist_export() {
  local outfile="${1:-$HOME/.zsh_history_export}"
  local total=0

  sqlite3 -escape off -cmd ".timeout 1000" "$RANKED_HIST_DB" \
    "SELECT printf('%d', last_used_ts) || char(30) || replace(cmd, char(10), char(30))
     FROM commands WHERE is_fragment = 0
     ORDER BY last_used_ts ASC" 2>/dev/null \
  | while IFS= read -r line; do
      local ts="${line%%$_RANKED_HIST_RS*}"
      local cmd="${line#*$_RANKED_HIST_RS}"
      cmd="${cmd//$_RANKED_HIST_RS/$_RANKED_HIST_NL}"
      printf ': %s:0;%s\n' "$ts" "$cmd"
      (( total++ ))
    done > "$outfile"

  echo "Exported $total commands to $outfile"
}

# --- Task 10: Import existing history ---

_ranked_hist_import() {
  local LC_ALL=C
  local -a files=("$@")
  (( ${#files} == 0 )) && files=("$HOME/.zsh_history" "$ZSH_HISTORY_ARCHIVE")
  
  _ranked_hist_init_db

  local line cmd ts duration total=0 q="'"
  local -a sql_batch=()

  _import_flush_cmd() {
    local escaped="${cmd//$q/$q$q}"
    sql_batch+=("INSERT INTO commands(cmd, total_count, last_used_ts, first_used_ts) VALUES('$escaped', 1, ${ts}.0, ${ts}.0) ON CONFLICT(cmd) DO UPDATE SET last_used_ts = MAX(last_used_ts, ${ts}.0), first_used_ts = MIN(first_used_ts, ${ts}.0);")
    (( total++ ))
    # Split compound commands into fragments
    _ranked_hist_fragment_sql "$cmd" "${ts}.0"
    [[ -n "$REPLY" ]] && sql_batch+=("$REPLY")
  }

  local f
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    cmd="" ts=""
    while IFS= read -r line; do
      if [[ "$line" =~ '^: ([0-9]+):([0-9]+);(.*)$' ]]; then
        [[ -n "$cmd" ]] && _import_flush_cmd
        ts="${match[1]}"
        duration="${match[2]}"
        cmd="${match[3]}"
      else
        [[ -n "$cmd" ]] && cmd+=$'\n'"$line"
      fi
    done < "$f"
    [[ -n "$cmd" ]] && _import_flush_cmd
  done
  unfunction _import_flush_cmd

  # Execute as single transaction via stdin (avoids ARG_MAX limits)
  {
    echo "BEGIN;"
    printf '%s\n' "${sql_batch[@]}"
    echo "COMMIT;"
  } | sqlite3 -cmd ".timeout 1000" "$RANKED_HIST_DB"

  echo "Imported $total commands from ${(j:, :)files}"
}

# --- Task 12: Weight tuning from acceptance data ---

_ranked_hist_tune() {
  local now=$EPOCHREALTIME
  local n_total n_accepted
  n_total=$(_ranked_hist_sql "SELECT COUNT(*) FROM suggestion_log")
  n_accepted=$(_ranked_hist_sql "SELECT COUNT(*) FROM suggestion_log WHERE accepted=1")
  local n_rejected=$(( n_total - n_accepted ))

  if (( n_total == 0 )); then
    echo "No data. Enable with: RANKED_HIST_LOG_SUGGESTIONS=true"
    return 1
  fi

  printf 'Events: %d total, %d accepted (%d%%), %d rejected\n' \
    "$n_total" "$n_accepted" "$(( n_accepted * 100 / n_total ))" "$n_rejected"

  if (( n_total < 20 )); then
    echo "Need ≥20 events for tuning (have $n_total)"
    return 1
  fi

  echo "Grid-searching weights..."

  local result
  result=$(_ranked_hist_sql \
    "SELECT
       sl.accepted,
       1.0/(1.0 + ($now - cs.last_used_ts)/86400.0),
       min(cs.total_count, 100)/100.0,
       1.0/(1.0 + ($now - ce.last_used_ts)/86400.0),
       min(ce.total_count, 100)/100.0
     FROM suggestion_log sl
     JOIN commands cs ON cs.cmd = sl.suggestion
     JOIN commands ce ON ce.cmd = sl.executed" \
  | awk -F'|' '
    { acc[NR]=$1; sr[NR]=$2; sf[NR]=$3; er[NR]=$4; ef[NR]=$5; n=NR }
    END {
      if (n == 0) { print "NODATA"; exit }
      best = -1
      for (wr = 10; wr <= 70; wr += 5) {
        for (wf = 5; wf <= 60; wf += 5) {
          wp = 100 - wr - wf
          if (wp < 5) continue
          c = 0
          for (i = 1; i <= n; i++) {
            ss = wr*sr[i] + wf*sf[i]
            es = wr*er[i] + wf*ef[i]
            if (acc[i] ? ss >= es : es >= ss) c++
          }
          if (c > best) { best=c; bwr=wr; bwp=wp; bwf=wf }
        }
      }
      printf "%.2f|%.2f|%.2f|%d|%d\n", bwr/100, bwp/100, bwf/100, best, n
    }')

  if [[ "$result" == "NODATA" || -z "$result" ]]; then
    echo "Could not match log entries to commands in DB"
    return 1
  fi

  local w_r w_p w_f correct total
  IFS='|' read -r w_r w_p w_f correct total <<< "$result"
  local pct=$(( correct * 100 / total ))

  printf 'Current weights:  W_RECENCY=%s  W_PWD=%s  W_FREQ=%s\n' \
    "$RANKED_HIST_W_RECENCY" "$RANKED_HIST_W_PWD" "$RANKED_HIST_W_FREQ"
  printf 'Tuned weights:    W_RECENCY=%s  W_PWD=%s  W_FREQ=%s\n' "$w_r" "$w_p" "$w_f"
  printf 'Improvement: %d/%d rejected events (%d%%) would rank correctly\n' "$correct" "$total" "$pct"

  _ranked_hist_sql \
    "INSERT INTO tuned_weights(id, w_recency, w_pwd, w_freq, acceptance_rate, sample_size, tuned_at)
     VALUES(1, $w_r, $w_p, $w_f, $(( n_accepted * 100 / n_total )), $n_total, $now)
     ON CONFLICT(id) DO UPDATE SET
       w_recency=$w_r, w_pwd=$w_p, w_freq=$w_f,
       acceptance_rate=$(( n_accepted * 100 / n_total )), sample_size=$n_total, tuned_at=$now"

  echo "Stored. Apply with: RANKED_HIST_USE_TUNED_WEIGHTS=true"
}

# --- Wire-up ---

_ranked_hist_init_db
# Load tuned weights if enabled
if [[ "$RANKED_HIST_USE_TUNED_WEIGHTS" == true ]]; then
  local _tw
  _tw=$(sqlite3 -cmd ".timeout 1000" "$RANKED_HIST_DB" \
    "SELECT w_recency || '|' || w_pwd || '|' || w_freq FROM tuned_weights WHERE id=1" 2>/dev/null)
  if [[ -n "$_tw" ]]; then
    IFS='|' read -r RANKED_HIST_W_RECENCY RANKED_HIST_W_PWD RANKED_HIST_W_FREQ <<< "$_tw"
  fi
  # Re-tune in background on every shell startup
  { _ranked_hist_tune } &>/dev/null &!
fi
_ranked_hist_populate_ring
zsh-defer _ranked_hist_load

# Hooks (guarded against double-sourcing)
# Prepend precmd (must be first to capture $?)
if [[ ${precmd_functions[(i)_ranked_hist_precmd]} -gt ${#precmd_functions} ]]; then
  precmd_functions=(_ranked_hist_precmd "${precmd_functions[@]}")
fi
# Append chpwd
if [[ ${chpwd_functions[(i)_ranked_hist_chpwd]} -gt ${#chpwd_functions} ]]; then
  chpwd_functions+=(_ranked_hist_chpwd)
fi

# Strategy chain
ZSH_AUTOSUGGEST_STRATEGY=(ranked_history completion)
ZSH_AUTOSUGGEST_CLEAR_WIDGETS+=(
  _ranked_hist_global_up
  _ranked_hist_global_down
)
