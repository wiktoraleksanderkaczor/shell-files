#!/usr/bin/env zsh
# Ralph Loop — dual-agent iteration via Kiro CLI
# Worker agent iterates on a task until self-reporting done.
# Gate agent independently verifies completion.
#
# KNOWN ISSUES & SOLUTIONS
# ========================
#
# 1. ansifilter race condition
#    Problem:  `tee >(ansifilter > file)` spawns ansifilter as async background
#              process. File may not be fully written when read by subsequent code.
#    Solution: Capture `$pipestatus` immediately after pipeline, then call `wait`
#              to block until ansifilter finishes before reading the output file.
#
# 2. Agent timeout with no context
#    Problem:  When kiro-cli is killed by `timeout`, the next retry or round has
#              no idea what went wrong or what the agent was doing when it died.
#    Solution: Detect exit code 124 (timeout), extract last command from captured
#              kiro output via "I will run the following command:" pattern, append
#              a TIMEOUT caution with the last command to the agent log so the
#              next invocation sees it in prompt context.
#
# 3. Ctrl+C loses progress
#    Problem:  Default EXIT trap cleaned up signal files but also removed state
#              needed for `--continue` (agent log, diff, round number).
#    Solution: Separate INT trap (`on_interrupt`) that captures current diff,
#              saves it, logs elapsed time, prints resume instructions, then
#              cleans up only transient files. Agent log and round file persist.
#
# 4. fs_write edits not tracked in worker-files
#    Problem:  `extract_worker_files` only parsed shell commands from kiro output
#              ("I will run the following command:"). Files modified via kiro's
#              `fs_write` tool never appeared in the file list.
#    Solution: Also extract changed files from `git diff --name-only` and new
#              untracked files, catching all modifications regardless of tool.
#
# 5. Duplicate paths in worker-files
#    Problem:  kiro output produces absolute paths, git commands produce relative
#              paths. Same file appears twice with different formats.
#    Solution: Normalize all paths to absolute (`sed "s|^[^/]|$PWD/&|"`) before
#              `sort -uo` deduplication.
#
# 6. Agents re-running verification commands
#    Problem:  Worker agent would run the same verification command that the
#              runtime runs via `--verify-cmd`, wasting time and context.
#    Solution: When `--verify-cmd` is set, worker prompt includes explicit rule
#              telling the agent not to run it — the runtime handles execution
#              and passes results back on failure.
#
# 7. Agent commands hanging or scanning too broadly
#    Problem:  Agents run `find /`, `grep -r` from repo root, or other unbounded
#              commands that hang or produce massive output.
#    Solution: All prompts include shell rules requiring `zsh -c` for all commands,
#              `timeout` wrapping for anything that could hang, and mandatory
#              narrow directory scoping for file discovery commands.
#
# 8. Agents lose context between rounds
#    Problem:  Each round starts fresh — agent doesn't know what commands failed,
#              where key files live, or what dead ends were already explored.
#    Solution: All prompts include "loop context tips" instructions telling agents
#              to record actionable intel in their summaries: failed commands with
#              errors, key file locations, search shortcuts, codebase patterns,
#              and dead ends. These persist in the agent log across rounds.
#
# 9. Agents waste time re-reading known files
#    Problem:  Reflection and gate agents re-read every file the worker touched,
#              burning context window and wall time on redundant `cat -n` calls.
#    Solution: File contents inlined into prompts by default (from worker-files
#              list, which includes both read and modified files). Each file
#              wrapped in `<file_content path="path">` with line numbers. Disabled via
#              `--no-include-files` if context window is a concern.
#
# 10. Verify command output invisible
#     Problem:  `zsh -c "$VERIFY_CMD" > file 2>&1` sent output only to file.
#               Operator couldn't see verification results in real time.
#     Solution: Replaced with `| tee "$VERIFY_OUTPUT"`, exit code captured via
#               `${pipestatus[1]}` for reliability with `set -o pipefail`.
#
# 11. Reflection/gate re-verify unchanged files
#     Problem:  On subsequent verification cycles, reflection and gate agents
#               re-examined every file from scratch — even files the worker
#               never touched since the last cycle.
#     Solution: After each verification cycle, save md5 checksums of all worker
#               files to `.ralph/verified-manifest`. Before the next cycle,
#               compare current checksums against the manifest to produce a
#               delta list of changed/new files. Prompts include this delta in
#               a `<worker_delta>` block with EFFICIENCY instructions telling
#               agents to skip re-verifying files not in the delta.
#
# 12. Reflection/gate verify pre-existing dirty state and user edits
#     Problem:  `git diff $BASELINE` and `extract_worker_files` attributed all
#               changes since baseline to the agent — including pre-existing
#               uncommitted changes and edits made by the user during runtime.
#     Solution: `save_pre_round_manifest` snapshots md5 checksums of all
#               tracked+dirty files before each worker round. After the round,
#               `files_changed_in_round` compares checksums to identify only
#               files the agent actually changed. `fmt_agent_diff_block` filters
#               the cumulative diff to agent-touched files only. Reflection and
#               gate prompts include a SCOPE instruction to ignore non-agent
#               changes. Worker prompt includes a rule to preserve user changes.
#
# DESIGN DECISIONS
# ================
#
# Agent ordering: Worker → Verify → Reflection → Gate
#   Verify command runs immediately after worker signals done so both reflection
#   and gate see the output. Reflection checks breadth of thinking (unexplored
#   avenues, blind spots) with verify results as additional signal. Gate runs
#   last as the strictest check — it sees reflection feedback, verify output,
#   and the full diff.
#
# Single chronological agent log
#   All agents write to one shared log (`.ralph/agent-log`) rather than separate
#   files. Every prompt inlines the full log. This means the worker sees gate
#   feedback, the gate sees worker reasoning, and reflection sees everything.
#   Trade-off: log grows with rounds, consuming context window. Acceptable
#   because multi-round runs rarely exceed 5-10 rounds.
#
# Worker signals completion explicitly
#   Worker writes a token file rather than relying on output parsing or exit
#   codes. This avoids false positives from the model saying "I'm done" in
#   conversation while still having work to do. The token must be the only
#   content in the file — no explanation, no extra text.
#
# Prompts saved to disk
#   Every prompt sent to every agent is saved to `.ralph/prompts/{label}_r{N}.txt`.
#   Enables post-hoc debugging of what each agent actually saw, prompt size
#   tracking, and diffing prompts between rounds to understand what changed.
#
# File contents inlined by default
#   Inlining previously-read and modified files saves agents from re-reading,
#   which is the single largest time sink in multi-round loops. Disabled via
#   `--no-include-files` for projects with many large files where context
#   window pressure outweighs the time savings.
#
# Git-based file tracking over output parsing
#   `extract_worker_files` uses `git diff --name-only` in addition to parsing
#   kiro output. Output parsing is fragile (depends on kiro-cli's exact format)
#   and misses tool-based edits. Git catches everything that actually changed
#   on disk regardless of how it was modified.
#
# Timeout with retry, not abort
#   Agent timeout triggers up to 3 retries with a caution message appended to
#   the agent log. The caution includes the last command before timeout so the
#   agent can avoid repeating it. Retries are preferred over abort because
#   partial work from the timed-out session persists on disk.
#
# Verify command runs in separate zsh process
#   `zsh -c "$VERIFY_CMD"` isolates the verification from the ralph-loop shell.
#   Prevents the verify command from modifying ralph-loop's environment, and
#   ensures consistent shell behavior regardless of the operator's shell config.
#
# Git wrapper strips `--exclude-standard` from `git grep`
#   kiro-cli's agent appends `--exclude-standard` to `git grep` calls, which
#   causes failures in some repository configurations. A wrapper script is
#   injected at the front of `$PATH` that intercepts `git grep` and strips
#   the flag before delegating to the real git binary. Transparent to all
#   other git subcommands.
#
# Non-git repository support
#   For directories without a git repo, the script bootstraps a temporary git
#   repo at `.ralph/.git` with `GIT_DIR`/`GIT_WORK_TREE` exports. An empty
#   baseline commit is created, and `.ralph` is added to the exclude list.
#   This enables `git diff`, `git ls-files`, and all diff-based features
#   without requiring the project to use git. The temporary repo persists
#   across `--continue` runs.
#
# `--continue` state model
#   Preserved across runs: agent log, worker log, gate log, round number,
#   git baseline ref, pre-untracked file list, task description, worker files,
#   timings, prompts, summary. NOT preserved: flags (`--verify-cmd`, `--fast`,
#   `--long`, etc.) — these must be re-specified on the `--continue` invocation.
#   The original task is loaded from `.ralph/task` and the new argument is
#   appended as additional instructions.
#
# `git add -N` for new file visibility
#   `stage_new_untracked` runs `git add -N` (intent-to-add) on new files after
#   each worker round. Without this, newly created files are invisible to
#   `git diff` and would be missing from the cumulative diff passed to
#   reflection and gate agents. The `-N` flag registers the file without
#   staging content, so `git diff` shows the full file as added.
#
# Checksum-based delta tracking for verification cycles
#   After each reflection/gate cycle, `save_verified_manifest` writes md5
#   checksums of all worker-touched files to `.ralph/verified-manifest`.
#   Before the next cycle, `build_worker_delta` compares current checksums
#   against the manifest to identify files the worker changed since the last
#   verification. Reflection and gate prompts include this delta list in a
#   `<worker_delta>` block so agents skip re-verifying unchanged files.
#   Trade-off: relies on md5 for change detection (fast, sufficient for
#   non-adversarial use). Manifest is saved after both pass and fail outcomes
#   so the delta always reflects one round of worker changes.
#
# Per-round manifest for agent-only change attribution
#   `save_pre_round_manifest` captures md5 checksums of all tracked and dirty
#   files before each worker round. `files_changed_in_round` compares post-round
#   checksums to identify files the agent actually modified — excluding
#   pre-existing uncommitted changes and user runtime edits. This feeds into
#   `extract_worker_files` (replacing the old `git diff --name-only $BASELINE`
#   approach) and `fmt_agent_diff_block` (which filters the cumulative diff to
#   agent-touched files only for reflection/gate prompts). Trade-off: checksums
#   every tracked file before each round, adding a few seconds of overhead.
#   Acceptable because worker rounds take minutes.
#
# Git worktree isolation (default)
#   By default, ralph-loop creates a git worktree under
#   `.ralph/runs/<run-id>/worktree` on a temporary branch
#   (`ralph/<timestamp>` or `--branch`). Each run is namespaced by run ID
#   (derived from branch name) so multiple runs execute in parallel without
#   collision. Pre-existing dirty state (staged, unstaged, untracked) is
#   transferred via `git stash create` + `stash apply` for tracked changes
#   and `tar` for untracked files. Context files (`REPOMAP*.md`,
#   `.project_state`) are copied since they may be gitignored. After
#   transfer, `snapshot_pre` baselines the worktree state so diffs only
#   capture agent changes. On successful exit, the diff is copied to
#   `.ralph/runs/<run-id>/diff` (applicable via `git apply`) and the
#   worktree + branch are removed. On interrupt, the worktree is preserved
#   for `--continue`. `--continue` auto-detects the run if only one is
#   active; otherwise `--branch` is required to select. Opt out with
#   `--no-worktree` to run in the current tree.

set -euo pipefail

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
ralph-loop — dual-agent task loop via Kiro CLI

USAGE
  ralph-loop.zsh [OPTIONS] "<task description>"
  ralph-loop.zsh [OPTIONS] --continue "<additional instructions>"

OPTIONS
  --fast              Use Claude Sonnet 4.6 (faster, cheaper)
  --dumb              Use Claude Haiku 4.5 (fastest, cheapest)
  --long              Append -1m context window (Opus and Sonnet only)
  --continue          Resume from prior run with additional instructions
  --verify-cmd CMD    Shell command to run after reflection, before gate-check.
                      Output is passed to gate and worker (on retry) as context.
  --agent AGENT       Kiro CLI agent to use (default: "ralph")
  --no-include-files  Do not inline previously-read and modified file contents
                      into prompts. By default, file contents are inlined so
                      agents skip re-reading them.
  --plan              Plan-only mode: agent produces a plan in ./plan.md
                      without modifying any other files.
  --interactive       Run kiro-cli without --no-interactive (allows agent
                      to prompt for input mid-run).
  -h, --help          Show this help

DESCRIPTION
  Runs three AI agents in a loop to complete a task with independent verification.

  Worker agent executes the task iteratively. Each round it receives the task
  description, the full agent log, and (on round 2+) the cumulative diff of all
  changes. Round 1 includes the project structure from REPOMAP.md if available.
  It works until it self-reports completion by writing a signal token. If it
  doesn't signal done, it loops automatically for another round.

  Reflection agent runs after the worker signals completion. It receives the
  full task, agent log, cumulative diff, and worker file list. It checks for
  unexplored avenues, blind spots, and alternative approaches. If it finds
  gaps, the worker resumes.

  Gate-check agent runs after reflection passes. It receives the same context
  as reflection and exhaustively verifies every ask is addressed, traces
  cascading codebase effects, checks for regressions, and looks for incomplete
  work. If verification fails, the worker resumes.

  All agents share a single chronological log (.ralph/agent-log). Each agent
  writes a summary per round, appended to this log. Every subsequent agent
  invocation receives the full log — worker sees prior gate/reflection feedback,
  gate sees all worker rounds, etc. The log is inlined into every prompt.

DIFF OUTPUT
  In git repositories, a working tree snapshot is taken before the loop starts
  using `git stash create` (no commits, no working tree modification). On
  completion, a diff of all agent changes (including new untracked files) is
  saved to .ralph/diff.

FILES (created in .ralph/ directory)
  .ralph/worker-signal   Worker completion token (cleaned up on exit)
  .ralph/gate-signal     Gate pass/fail token (cleaned up on exit)
  .ralph/reflect-signal  Reflection pass/fail token (cleaned up on exit)
  .ralph/agent-msg       Current agent's summary (cleaned up on exit)
  .ralph/agent-log       Combined agent messages for prompt context (persisted)
  .ralph/worker-log      Accumulated worker messages across all rounds (persisted)
  .ralph/gate-log        Accumulated gate verification reports (persisted)
  .ralph/diff            Git diff of all agent changes (persisted)
  .ralph/summary         Human-readable summary of completed work (persisted)
  .ralph/baseline        Git baseline ref for diff (persisted)
  .ralph/pre-untracked   Pre-run untracked file list for diff (persisted)
  .ralph/task            Original task description for --continue (persisted)
  .ralph/timings         Per-agent and total elapsed times (persisted)
  .ralph/prompts/        Generated prompts per agent per round (persisted)
  .ralph/verify-output   Verify command output (cleaned up on exit)
  .ralph/worker-files    Absolute paths of files read/modified (persisted)

EXAMPLES
  ./ralph-loop.zsh "Refactor auth module to use JWT tokens"
  ./ralph-loop.zsh --fast "Add pagination to the /users API endpoint"
  ./ralph-loop.zsh --fast --long "Large refactor across many files"
  ./ralph-loop.zsh --dumb "Fix typo in README"
  ./ralph-loop.zsh --verify-cmd "npm test 2>&1" "Add pagination to /users"
  ./ralph-loop.zsh --agent coding "Implement the new feature"
  ./ralph-loop.zsh --continue "Also handle the edge case in auth.js"
EOF
  exit 0
}

# ─── Parse arguments ──────────────────────────────────────────────────────────

KIRO_MODEL_FLAG=""
KIRO_AGENT="ralph"
LONG=false
CONTINUE=false
VERIFY_CMD=""
INCLUDE_FILES=true
PLAN_MODE=false
INTERACTIVE=false
WORKTREE=true
WORKTREE_BRANCH=""
while [[ "${1:-}" == -* ]]; do
  case "$1" in
    -h|--help) usage ;;
    --fast)           KIRO_MODEL_FLAG="claude-sonnet-4.6"; shift ;;
    --dumb)           KIRO_MODEL_FLAG="claude-haiku-4.5"; shift ;;
    --long)           LONG=true; shift ;;
    --continue)       CONTINUE=true; shift ;;
    --verify-cmd)     VERIFY_CMD="${2:?--verify-cmd requires a command string}"; shift 2 ;;
    --agent)          KIRO_AGENT="${2:?--agent requires an agent name}"; shift 2 ;;
    --no-include-files)  INCLUDE_FILES=false; shift ;;
    --plan)              PLAN_MODE=true; shift ;;
    --interactive)       INTERACTIVE=true; shift ;;
    --no-worktree)       WORKTREE=false; shift ;;
    --branch)            WORKTREE_BRANCH="${2:?--branch requires a branch name}"; shift 2 ;;
    *)                echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
if $LONG && [[ "$KIRO_MODEL_FLAG" != "claude-haiku-4.5" ]]; then
  KIRO_MODEL_FLAG="${KIRO_MODEL_FLAG:-claude-opus-4.6}-1m"
fi
TASK="${1:?Usage: $0 \"<task description>\" (try --help)}"
if $WORKTREE && [[ -z "$WORKTREE_BRANCH" ]] && ! $CONTINUE; then
  echo "Error: --branch is required for worktree runs." >&2
  exit 1
fi

# ─── Paths & tokens ──────────────────────────────────────────────────────────

RALPH_STATE=".ralph/local"
$WORKTREE && RALPH_STATE=".ralph"

WORKER_SIGNAL="$RALPH_STATE/worker-signal"
GATE_SIGNAL="$RALPH_STATE/gate-signal"
REFLECT_SIGNAL="$RALPH_STATE/reflect-signal"
WORKER_TOKEN="RALPH_WORKER_DONE"
GATE_PASS_TOKEN="RALPH_GATE_PASSED"
GATE_FAIL_TOKEN="RALPH_GATE_FAILED"
REFLECT_PASS_TOKEN="RALPH_REFLECT_PASSED"
REFLECT_FAIL_TOKEN="RALPH_REFLECT_FAILED"

AGENT_LOG="$RALPH_STATE/agent-log"
WORKER_LOG="$RALPH_STATE/worker-log"
GATE_LOG="$RALPH_STATE/gate-log"
AGENT_MSG="$RALPH_STATE/agent-msg"
RALPH_DIFF="$RALPH_STATE/diff"
RALPH_SUMMARY="$RALPH_STATE/summary"
RALPH_TASK="$RALPH_STATE/task"
RALPH_LOCK="$RALPH_STATE/lock"
RALPH_ROUND_FILE="$RALPH_STATE/round"
RALPH_BASELINE_FILE="$RALPH_STATE/baseline"
RALPH_PRE_UNTRACKED_FILE="$RALPH_STATE/pre-untracked"
WORKER_FILES="$RALPH_STATE/worker-files"
VERIFIED_MANIFEST="$RALPH_STATE/verified-manifest"
PRE_ROUND_MANIFEST="$RALPH_STATE/pre-round-manifest"
KIRO_OUTPUT="$RALPH_STATE/kiro-output"
VERIFY_OUTPUT="$RALPH_STATE/verify-output"
RALPH_TIMINGS="$RALPH_STATE/timings"

BASELINE=""
PRE_UNTRACKED=""
CURRENT_DIFF=""
AGENT_TIMEOUT="30m"
REPOMAP=""
[[ -f "REPOMAP.md" ]] && REPOMAP=$(<"REPOMAP.md")
ORIG_DIR="$PWD"
WORKTREE_DIR=""
RALPH_RUN_BRANCH="${WORKTREE_BRANCH:-ralph/$(date +%Y%m%d-%H%M%S)}"
# Ensure unique run ID if another run started in the same second
while [[ -z "$WORKTREE_BRANCH" && -d ".ralph/runs/${RALPH_RUN_BRANCH//\//-}" ]]; do
  sleep 1
  RALPH_RUN_BRANCH="ralph/$(date +%Y%m%d-%H%M%S)"
done
if [[ -n "$WORKTREE_BRANCH" ]]; then
  RALPH_RUN_ID="ralph-${WORKTREE_BRANCH//\//-}-$(date +%Y%m%d-%H%M%S)"
else
  RALPH_RUN_ID="${RALPH_RUN_BRANCH//\//-}"
fi
RALPH_RUN_DIR=".ralph/runs/$RALPH_RUN_ID"
RALPH_WORKTREE_FILE="$RALPH_RUN_DIR/worktree-dir"

# ─── Helpers ──────────────────────────────────────────────────────────────────

GIT_WRAPPER_DIR=""
setup_git_wrapper() {
  GIT_WRAPPER_DIR=$(mktemp -d)
  local real_git=$(command -v git)
  cat > "$GIT_WRAPPER_DIR/git" <<WRAPPER
#!/usr/bin/env zsh
if [[ "\${1:-}" == "grep" ]]; then
  shift
  set -- grep "\${@:#--*exclude-standard}"
fi
exec "$real_git" "\$@"
WRAPPER
  chmod +x "$GIT_WRAPPER_DIR/git"
  export PATH="$GIT_WRAPPER_DIR:$PATH"
}

setup_worktree() {
  $WORKTREE || return 0
  git rev-parse --is-inside-work-tree &>/dev/null || { echo "Warning: not a git repo, skipping worktree." >&2; WORKTREE=false; return 0; }

  local branch="$RALPH_RUN_BRANCH"
  WORKTREE_DIR="${ORIG_DIR}/${RALPH_RUN_DIR}/worktree"

  # Create run directory, branch + worktree
  mkdir -p "${ORIG_DIR}/${RALPH_RUN_DIR}"
  git branch "$branch" HEAD 2>/dev/null || true
  git worktree add -q "$WORKTREE_DIR" "$branch"
  echo "$WORKTREE_DIR" > "$RALPH_WORKTREE_FILE"

  # Copy context files (may be gitignored)
  for f in "$ORIG_DIR"/REPOMAP*.md "$ORIG_DIR"/.project_state; do
    [[ -f "$f" ]] && cp "$f" "$WORKTREE_DIR/"
  done

  # Transfer dirty state: staged + unstaged + untracked
  local stash_ref=$(git -C "$ORIG_DIR" stash create 2>/dev/null || true)
  if [[ -n "$stash_ref" ]]; then
    git -C "$WORKTREE_DIR" stash apply --quiet "$stash_ref" 2>/dev/null || true
  fi
  # Untracked files — tar to preserve paths
  local untracked=$(git -C "$ORIG_DIR" ls-files --others --exclude-standard)
  if [[ -n "$untracked" ]]; then
    echo "$untracked" | tar -cf - -C "$ORIG_DIR" -T - 2>/dev/null | tar -xf - -C "$WORKTREE_DIR" 2>/dev/null || true
  fi

  cd "$WORKTREE_DIR"
  echo "📂 Worktree: $WORKTREE_DIR (branch: $branch)"
}

cleanup_worktree() {
  # Worktree preserved for inspection and --continue.
  [[ -n "$WORKTREE_DIR" && -d "$WORKTREE_DIR" ]] || return 0
  echo "📂 Worktree preserved: $WORKTREE_DIR"
}

cleanup() {
  rm -f "$WORKER_SIGNAL" "$GATE_SIGNAL" "$REFLECT_SIGNAL" "$AGENT_MSG" "$KIRO_OUTPUT" "$VERIFY_OUTPUT" "$RALPH_LOCK"
  [[ -n "$GIT_WRAPPER_DIR" ]] && rm -rf "$GIT_WRAPPER_DIR"
}

on_interrupt() {
  echo "\n\n⚠ Interrupted. Preserving state for --continue..."
  build_diff 2>/dev/null || true
  [[ -n "$CURRENT_DIFF" ]] && echo "$CURRENT_DIFF" > "$RALPH_DIFF"
  [[ -n "${LOOP_START:-}" ]] && log_timing "Total (interrupted)" $((SECONDS - LOOP_START))
  echo "  Agent log: $AGENT_LOG"
  echo "  Diff:      $RALPH_DIFF"
  echo "  Resume:    $0 --continue \"<instructions>\""
  cleanup
  exit 130
}

# Returns new untracked files (not in PRE_UNTRACKED, not under .ralph/).
new_untracked_files() {
  local all=$(git ls-files --others --exclude-standard 2>/dev/null)
  while IFS= read -r f; do
    [[ -z "$f" || "$f" == .ralph/* ]] && continue
    echo "$PRE_UNTRACKED" | grep -qxF "$f" && continue
    echo "$f"
  done <<< "$all"
}

# Builds cumulative diff (tracked changes + new untracked files) into CURRENT_DIFF.
build_diff() {
  CURRENT_DIFF=$(git diff --text "$BASELINE" -- ':!.ralph/*' 2>/dev/null \
    | LC_ALL=C tr -cd '[:print:]\t\n' || true)
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    CURRENT_DIFF+=$'\n'"$(git diff --text --no-index /dev/null "$f" 2>/dev/null \
      | LC_ALL=C tr -cd '[:print:]\t\n' || true)"
  done <<< "$(new_untracked_files)"
}

log_timing() {
  local label=$1 elapsed=$2
  local m=$((elapsed / 60)) s=$((elapsed % 60))
  local fmt="${m}m${s}s"
  echo "⏱ $label: $fmt"
  echo "$label: $fmt" >> "$RALPH_TIMINGS"
}

# Checks whether a signal file contains the expected token.
check_signal() {
  local file=$1 token=$2
  [[ -f "$file" ]] && [[ "$(tr -d '[:space:]' < "$file")" == "$token" ]]
}

# ─── Git snapshots ────────────────────────────────────────────────────────────

snapshot_pre() {
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    if $CONTINUE && [[ -f "$RALPH_BASELINE_FILE" ]]; then
      BASELINE=$(<"$RALPH_BASELINE_FILE")
      PRE_UNTRACKED=""
      [[ -f "$RALPH_PRE_UNTRACKED_FILE" ]] && PRE_UNTRACKED=$(<"$RALPH_PRE_UNTRACKED_FILE")
    else
      BASELINE=$(git stash create 2>/dev/null || true)
      [[ -z "$BASELINE" ]] && BASELINE=HEAD
      PRE_UNTRACKED=$(git ls-files --others --exclude-standard)
      echo "$BASELINE" > "$RALPH_BASELINE_FILE"
      echo "$PRE_UNTRACKED" > "$RALPH_PRE_UNTRACKED_FILE"
    fi
  else
    export GIT_DIR="$PWD/$RALPH_STATE/.git"
    export GIT_WORK_TREE="$PWD"
    if $CONTINUE && [[ -d "$GIT_DIR" ]]; then
      BASELINE=$(<"$RALPH_BASELINE_FILE")
      PRE_UNTRACKED=""
      [[ -f "$RALPH_PRE_UNTRACKED_FILE" ]] && PRE_UNTRACKED=$(<"$RALPH_PRE_UNTRACKED_FILE")
    else
      git init -q
      echo ".ralph" >> "$GIT_DIR/info/exclude"
      git commit -q --allow-empty -m "ralph baseline"
      BASELINE=HEAD
      PRE_UNTRACKED=$(git ls-files --others --exclude-standard)
      echo "$BASELINE" > "$RALPH_BASELINE_FILE"
      echo "$PRE_UNTRACKED" > "$RALPH_PRE_UNTRACKED_FILE"
    fi
  fi
}

snapshot_post() {
  build_diff
  echo "$CURRENT_DIFF" > "$RALPH_DIFF"
  if [[ -s "$RALPH_DIFF" ]]; then
    # In worktree mode, copy diff to original directory for easy git apply
    if [[ -n "$WORKTREE_DIR" && "$PWD" == "$WORKTREE_DIR"* ]]; then
      local out_diff="$ORIG_DIR/${RALPH_RUN_DIR}/diff"
      cp "$RALPH_DIFF" "$out_diff"
      echo "\n📄 Agent diff saved to $out_diff"
      echo "   Apply with: cd $ORIG_DIR && git apply ${RALPH_RUN_DIR}/diff"
    else
      echo "\n📄 Agent diff saved to $RALPH_DIFF"
    fi
  else
    rm -f "$RALPH_DIFF"
    echo "\n📄 No file changes detected."
  fi
}

stage_new_untracked() {
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    git add -N "$f"
  done <<< "$(new_untracked_files)"
}

# ─── Kiro runner (with retry) ────────────────────────────────────────────────

last_agent_cmd() {
  [[ -f "$KIRO_OUTPUT" ]] || return 0
  sed 's/\x1b\[[0-9;]*m//g' "$KIRO_OUTPUT" \
    | grep -oE 'I will run the following command: .+' \
    | sed 's/I will run the following command: //; s/ (using tool:.*//' \
    | tail -1
}

timeout_msg() {
  local last=$(last_agent_cmd)
  local msg="── TIMEOUT ── Agent timed out after $AGENT_TIMEOUT."
  [[ -n "$last" ]] && msg+=" Last command before timeout: \`$last\`"
  msg+=" CAUTION: on retry, work more efficiently — scope searches tightly, avoid unnecessary file reads, break work into smaller steps, and write your summary to $AGENT_MSG early so progress is not lost on another timeout."
  echo "$msg"
}

run_kiro() {
  local prompt_file=$1
  local args=(chat --trust-all-tools --agent "$KIRO_AGENT")
  $INTERACTIVE || args+=(--no-interactive)
  [[ -n "$KIRO_MODEL_FLAG" ]] && args+=(--model "$KIRO_MODEL_FLAG")
  local attempt rc
  for attempt in 1 2 3; do
    set +e
    timeout "$AGENT_TIMEOUT" kiro-cli "${args[@]}" < "$prompt_file" 2>&1 | tee >(ansifilter > "$KIRO_OUTPUT")
    rc=${pipestatus[1]}
    set -e
    wait
    if (( rc == 0 )); then return 0; fi
    if (( rc == 124 )); then
      timeout_msg >> "$AGENT_LOG"
      local last=$(last_agent_cmd)
      echo "\n⚠ Agent timed out after $AGENT_TIMEOUT (attempt $attempt/3).${last:+ Last command: $last}" >&2
    else
      echo "\n⚠ kiro-cli failed (attempt $attempt/3, exit $rc)." >&2
    fi
    echo "Retrying in 10s..." >&2
    sleep 10
  done
  echo "\n✗ kiro-cli failed after 3 attempts. Aborting." >&2
  return 1
}

# Saves prompt, runs kiro, logs timing. Usage: run_agent <file_label> <timing_label> <prompt>
run_agent() {
  local file_label=$1 timing_label=$2 prompt=$3
  local prompt_file="$PWD/$RALPH_STATE/prompts/${file_label}_r${round}.txt"
  echo "$prompt" > "$prompt_file"
  # Strip invalid UTF-8 sequences — kiro-cli rejects non-UTF-8 stdin
  LC_ALL=C tr -cd '[:print:]\t\n' < "$prompt_file" > "${prompt_file}.tmp" && mv "${prompt_file}.tmp" "$prompt_file"
  local t0=$SECONDS
  run_kiro "$prompt_file"
  log_timing "$timing_label" $((SECONDS - t0))
}

extract_worker_files() {
  # From kiro output: files referenced in shell commands
  if [[ -f "$KIRO_OUTPUT" ]]; then
    sed 's/\x1b\[[0-9;]*m//g' "$KIRO_OUTPUT" \
      | grep -oE 'I will run the following command: .+' \
      | sed 's/I will run the following command: //; s/ (using tool:.*//' \
      | tr ' \t|;' '\n' \
      | sed "s|^~|$HOME|" \
      | grep -E '^(/|\.\..?/)' \
      | grep -v '/\.ralph/' \
      | sort -u \
      | while IFS= read -r p; do
          stat "$p" &>/dev/null && echo "$p"
        done >> "$WORKER_FILES"
  fi
  # From git: files actually changed during this round (agent-only, via pre-round manifest)
  files_changed_in_round >> "$WORKER_FILES"
  # Normalize to absolute paths, then dedup
  sed -i '' "s|^[^/]|$PWD/&|" "$WORKER_FILES"
  sort -uo "$WORKER_FILES" "$WORKER_FILES" 2>/dev/null || true
}

# ─── Prompt building blocks ──────────────────────────────────────────────────

SHELL_RULES='SHELL RULES: Run all commands through `zsh -c`. Wrap any command that could hang with `timeout`. File discovery/search commands (`find`, `grep -r`, `git grep`, etc.) must target the narrowest relevant directory and always use `timeout` (e.g., `timeout 15 zsh -c '\''grep -rn pattern src/module/'\''`).'

loop_context_tips() {
  case "$1" in
    worker)
      cat <<EOF
LOOP CONTEXT TIPS — include these in your "$AGENT_MSG" summary so future rounds (yours, reflection, and gate) can work faster:
- Commands that failed and why (exact command, error message, root cause if known)
- Key file locations discovered (e.g., "config lives in src/config/app.ts", "tests are in __tests__/")
- Shortcuts for finding things (e.g., "grep -r 'AuthProvider' src/ to find all auth usage")
- Patterns or conventions observed in the codebase (e.g., "all API handlers follow handler(req, res) signature")
- Dead ends explored and why they didn't work — save the next round from repeating them
EOF
      ;;
    gate)
      cat <<EOF
LOOP CONTEXT TIPS — include these in your "$AGENT_MSG" summary so the worker can fix issues faster on retry:
- Exact file paths and line numbers where problems were found
- Commands to reproduce failures (e.g., "run \`grep -n 'oldName' src/\` to find remaining references")
- What specifically needs to change and where — be precise enough that the worker doesn't have to re-discover the problem
- Any codebase context you gathered that would save the worker time (e.g., "the config schema is defined in src/schema.ts:42")
EOF
      ;;
    reflect)
      cat <<EOF
LOOP CONTEXT TIPS — include these in your "$AGENT_MSG" summary so the worker and gate can work faster:
- Specific files or locations the worker should re-examine (exact paths)
- Commands or searches that would quickly verify your concerns
- Patterns you noticed that the worker may have missed
- Codebase conventions relevant to the task that should be followed
EOF
      ;;
  esac
}

fmt_agent_history() {
  local h=""
  [[ -f "$AGENT_LOG" ]] && h=$(<"$AGENT_LOG")
  echo "$h"
}

fmt_diff_block() {
  [[ -n "$CURRENT_DIFF" ]] || return 0
  echo "CURRENT DIFF — cumulative from baseline ref in \`$RALPH_BASELINE_FILE\` (includes ALL prior rounds, not just yours). Verify with: \`git diff \$(cat $RALPH_BASELINE_FILE)\`"
  echo "<diff>"
  echo "$CURRENT_DIFF" | awk '
    /^diff --git / {
      if (path) print "</file_diff>"
      path = $0; sub(/^diff --git a\/.* b\//, "", path)
      printf "<file_diff path=\"%s\">\n", path
    }
    { print }
    END { if (path) print "</file_diff>" }
  '
  echo "</diff>"
}

# Like fmt_diff_block but only includes files in WORKER_FILES (agent-touched).
fmt_agent_diff_block() {
  [[ -n "$CURRENT_DIFF" ]] || return 0
  [[ -s "$WORKER_FILES" ]] || return 0
  local filtered
  filtered=$(echo "$CURRENT_DIFF" | awk -v wf="$WORKER_FILES" '
    BEGIN { while ((getline f < wf) > 0) keep[f]=1 }
    /^diff --git / {
      path = $0; sub(/^diff --git a\/.* b\//, "", path)
      # Try both relative and absolute
      show = (path in keep) || (ENVIRON["PWD"] "/" path in keep)
    }
    show { print }
  ')
  [[ -n "$filtered" ]] || return 0
  echo "AGENT DIFF — only files changed by the agent (excludes pre-existing dirty state and user edits). Full cumulative diff: \`git diff \$(cat $RALPH_BASELINE_FILE)\`"
  echo "<diff>"
  echo "$filtered" | awk '
    /^diff --git / {
      if (path) print "</file_diff>"
      path = $0; sub(/^diff --git a\/.* b\//, "", path)
      printf "<file_diff path=\"%s\">\n", path
    }
    { print }
    END { if (path) print "</file_diff>" }
  '
  echo "</diff>"
}

# Shows diff --stat + modification times for non-agent changes (pre-existing + user edits).
fmt_external_changes_block() {
  [[ -n "$CURRENT_DIFF" ]] || return 0
  local all_changed
  all_changed=$(echo "$CURRENT_DIFF" | grep -oE '^diff --git a/.* b/(.*)' | sed 's|^diff --git a/.* b/||' | sort -u)
  [[ -n "$all_changed" ]] || return 0
  local external=""
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if [[ -s "$WORKER_FILES" ]]; then
      grep -qxF "$f" "$WORKER_FILES" && continue
      grep -qxF "$PWD/$f" "$WORKER_FILES" && continue
    fi
    local stat_line=$(git diff --stat "$BASELINE" -- "$f" 2>/dev/null | head -1)
    local mtime=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f" 2>/dev/null)
    external+="  $f  (modified: ${mtime:-unknown})  ${stat_line:+— $stat_line}"$'\n'
  done <<< "$all_changed"
  [[ -n "$external" ]] || return 0
  cat <<EOF
EXTERNAL CHANGES — files modified outside your control (pre-existing uncommitted changes or user edits during runtime). Do NOT revert or overwrite these. Be aware they exist in case of interactions with your work.
<external_changes>
${external%$'\n'}
</external_changes>
EOF
}

fmt_files_block() {
  [[ -s "$WORKER_FILES" ]] || return 0
  cat <<EOF
FILES ACCESSED BY WORKER (every file opened or read across all rounds):
<worker_files>
$(<"$WORKER_FILES")
</worker_files>
EOF
}

fmt_verify_block() {
  [[ -s "$VERIFY_OUTPUT" ]] || return 0
  cat <<EOF
VERIFY COMMAND OUTPUT (\`$VERIFY_CMD\`):
<verify_output>
$(<"$VERIFY_OUTPUT")
</verify_output>
EOF
}

build_file_contents_block() {
  $INCLUDE_FILES || return 0
  [[ -s "$WORKER_FILES" ]] || return 0
  local block=""
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    grep -qI '' "$f" 2>/dev/null || continue  # skip binary files
    block+="
<file_content path=\"$f\">
$(cat -n "$f")
</file_content>"
  done < "$WORKER_FILES"
  [[ -z "$block" ]] && return 0
  cat <<EOF
PREVIOUSLY-READ FILE CONTENTS — CRITICAL: Do NOT read, cat, sed, or open ANY file listed below — not even partial/targeted reads. These are the current contents on disk at agent start and will not change during your runtime unless you change them (which you should not). Re-reading them in any form wastes time and context window.
$block
EOF
}

# Snapshots md5 checksums of all tracked + dirty files before a worker round.
save_pre_round_manifest() {
  local tmp="${PRE_ROUND_MANIFEST}.tmp"
  { git diff --name-only "$BASELINE" -- ':!.ralph/*' 2>/dev/null
    git ls-files -- ':!.ralph/*' 2>/dev/null
    new_untracked_files
  } | sort -u | while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    echo "$(md5 -q "$f")  $f"
  done > "$tmp"
  mv "$tmp" "$PRE_ROUND_MANIFEST"
}

# Outputs files whose checksums changed since pre-round manifest (agent changes only).
files_changed_in_round() {
  [[ -f "$PRE_ROUND_MANIFEST" ]] || return 0
  { git diff --name-only "$BASELINE" -- ':!.ralph/*' 2>/dev/null
    new_untracked_files
  } | sort -u | while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    local cur=$(md5 -q "$f")
    local prev=$(grep -F "  $f" "$PRE_ROUND_MANIFEST" | head -1 | cut -d' ' -f1)
    [[ "$cur" == "$prev" ]] || echo "$f"
  done
}

# Saves md5 checksums of all worker files for delta tracking.
save_verified_manifest() {
  [[ -s "$WORKER_FILES" ]] || return 0
  local tmp="${VERIFIED_MANIFEST}.tmp"
  > "$tmp"
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    echo "$(md5 -q "$f")  $f" >> "$tmp"
  done < "$WORKER_FILES"
  mv "$tmp" "$VERIFIED_MANIFEST"
}

# Outputs list of files changed/added since last verified manifest.
build_worker_delta() {
  [[ -s "$WORKER_FILES" ]] || return 0
  if [[ ! -f "$VERIFIED_MANIFEST" ]]; then
    # No prior manifest — all files are new
    cat "$WORKER_FILES"
    return 0
  fi
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    local cur=$(md5 -q "$f")
    local prev=$(grep -F "  $f" "$VERIFIED_MANIFEST" | head -1 | cut -d' ' -f1)
    [[ "$cur" == "$prev" ]] || echo "$f"
  done < "$WORKER_FILES"
}

fmt_worker_delta_block() {
  local delta=$(build_worker_delta)
  [[ -n "$delta" ]] || return 0
  cat <<EOF
WORKER DELTA — files changed or added since last reflection/gate cycle. Only these require fresh verification; previously-verified unchanged files can be skipped.
<worker_delta>
$delta
</worker_delta>
EOF
}

# ─── Prompts ──────────────────────────────────────────────────────────────────

worker_prompt() {
  local agent_history=$(fmt_agent_history)
  local file_contents_block=$(build_file_contents_block)
  local verify_rule=""
  [[ -n "$VERIFY_CMD" ]] && verify_rule="- A verification command (\`$VERIFY_CMD\`) will be run automatically by the runtime after you signal completion. Do NOT run it yourself. If it fails, the output will be passed back to you in a subsequent round. Just focus on the task and signal done when ready."

  local continuation="" context_block=""
  if (( round == 1 )); then
    if [[ -n "$REPOMAP" ]]; then
      context_block="PROJECT STRUCTURE (from REPOMAP.md):
<project_structure>
$REPOMAP
</project_structure>"
    else
      context_block="No project map available. Explore the codebase as needed."
    fi
  else
    local last_header=$(echo "$agent_history" | grep -oE '── [A-Za-z-]+' | tail -1)
    if [[ "$last_header" == *"Gate-Check"* ]]; then
      continuation="You are resuming because the gate-check agent REJECTED your prior work. Read the gate feedback below carefully and address every item."
    elif [[ "$last_header" == *"Reflection"* ]]; then
      continuation="You are resuming because the reflection agent found unexplored avenues or blind spots. Read the reflection feedback below and address every item."
    else
      continuation="You are resuming because you did NOT write the completion token (\"$WORKER_TOKEN\") to \"$WORKER_SIGNAL\" last round. You must write exactly that token to that file when the task is fully complete. Review your prior progress below and continue."
    fi
    if [[ -n "$CURRENT_DIFF" ]]; then
      context_block="CURRENT DIFF — cumulative from baseline ref in \`$RALPH_BASELINE_FILE\` (includes ALL prior rounds, not just yours). Verify with: \`git diff \$(cat $RALPH_BASELINE_FILE)\`
$(echo "<diff>"; echo "$CURRENT_DIFF" | awk '
  /^diff --git / {
    if (path) print "</file_diff>"
    path = $0; sub(/^diff --git a\/.* b\//, "", path)
    printf "<file_diff path=\"%s\">\n", path
  }
  { print }
  END { if (path) print "</file_diff>" }
'; echo "</diff>")"
    fi
  fi

  cat <<EOF
You are the WORKER agent in an automated loop (round $round). Your task:

<task>
$TASK
</task>
${continuation:+
$continuation}
${context_block:+
$context_block}

FULL AGENT HISTORY (every worker and gate-check message from all prior rounds, in chronological order):
<agent_history>
$agent_history
</agent_history>
${file_contents_block:+
$file_contents_block}

RULES:
- Do NOT read, cat, sed, or open any file whose contents appear in XML blocks above (<file_content>, <diff>, <project_structure>) — not even partial or targeted reads. These reflect the current contents on disk at agent start and will not change during your runtime unless you change them (which you should not). Re-reading them in any form wastes time and context.
- Make progress on the task. If resuming, review the full history above (especially any gate-check failures) and address every unresolved item.
- When reading files, ALWAYS use \`cat -n\` to read the ENTIRE file with line numbers. No partial reads, no ranges, no truncation.
- Run ALL shell commands through \`zsh -c\`. Wrap any command that could hang or run long with \`timeout\` (e.g., \`timeout 30 zsh -c '...'\`).
- File discovery commands (\`find\`, \`ls -R\`, \`git ls-files\`, \`grep -r\`, \`git grep\`) MUST be scoped to the narrowest relevant directory — never scan from repo root when you know the target subtree. Always wrap these with \`timeout\` (e.g., \`timeout 15 find src/auth -name '*.ts'\`).
- When the task is FULLY COMPLETE, write EXACTLY the token "$WORKER_TOKEN" to the file "$WORKER_SIGNAL". The file must contain this token and nothing else — no explanation, no extra text.
- Do NOT write the token until you are confident the task is done.
- If the task is NOT done yet, do as much as you can this round. Do NOT write the token.
- ALWAYS write a concise summary of what you did this round to "$AGENT_MSG" (overwrite, not append). Include: changes made, files modified (list every file path), and current status.
${verify_rule:+$verify_rule}

$(loop_context_tips worker)
EOF
}

reflect_prompt() {
  local agent_history=$(fmt_agent_history)
  local diff_block=$(fmt_agent_diff_block)
  local files_block=$(fmt_files_block)
  local verify_block=$(fmt_verify_block)
  local file_contents_block=$(build_file_contents_block)
  local delta_block=$(fmt_worker_delta_block)
  cat <<EOF
You are the REFLECTION agent. A worker agent claims it completed this task:

<task>
$TASK
</task>

FULL AGENT HISTORY (every worker and gate-check message from all prior rounds):
<agent_history>
$agent_history
</agent_history>
${diff_block:+
$diff_block}
${files_block:+
$files_block}
${verify_block:+
$verify_block}
${file_contents_block:+
$file_contents_block}
${delta_block:+
$delta_block}

Your job is to think LATERALLY about whether the worker has considered all possible avenues, approaches, and implications. This is NOT a correctness check — a separate gate agent handles that. Your focus is BREADTH and COMPLETENESS OF THINKING.

REFLECTION PROCEDURE:

$SHELL_RULES

CRITICAL: Do NOT read, cat, sed, or open any file whose contents appear in XML blocks above (<file_content>, <diff>, <verify_output>) — not even partial or targeted reads. These reflect the current contents on disk at agent start and will not change during your runtime unless you change them (which you should not). Re-reading them in any form wastes time and context. Only read files NOT already provided when you need additional context.


1. AVENUE AUDIT: List every distinct approach, strategy, or angle that could apply to this task. For each, check whether the worker explored or consciously dismissed it. Flag any avenue that was neither explored nor justified as skipped.

2. EDGE CASE BRAINSTORM: Think about unusual inputs, boundary conditions, race conditions, platform differences, backwards compatibility, and failure modes. Did the worker account for these or are there blind spots?

3. SECOND-ORDER EFFECTS: What are the non-obvious consequences of the changes? Could they affect performance, security, usability, maintainability, or other parts of the system in ways the worker didn't consider?

4. ALTERNATIVE APPROACHES: Was there a simpler, more robust, or more idiomatic way to accomplish the task that the worker missed? If so, is the chosen approach still acceptable or should it be reconsidered?

5. MISSING PERSPECTIVES: Step outside the immediate code changes. Are there user-facing implications, documentation needs, configuration changes, or operational concerns that were overlooked?

DEFAULT STANCE: Assume something was missed until you've verified otherwise. Better to send the worker back for one more round of consideration than to let a blind spot through.

EFFICIENCY: The <worker_delta> block above (if present) lists files changed since the last reflection/gate cycle. For files NOT in that list, your prior verification still holds — do not re-examine them. Focus exclusively on changed/new files and any previously-raised concerns that remain unresolved. If no delta block is present, this is the first verification cycle — examine everything.

DECISION:
- If the worker has genuinely considered all reasonable avenues and the approach is sound, write EXACTLY "$REFLECT_PASS_TOKEN" to "$REFLECT_SIGNAL". The file must contain this token and nothing else.
- If there are unexplored avenues or blind spots worth addressing, write EXACTLY "$REFLECT_FAIL_TOKEN" to "$REFLECT_SIGNAL" (token only, nothing else).
- ALWAYS write a concise summary of your findings to "$AGENT_MSG" (overwrite, not append). On failure, list EVERY unexplored avenue or blind spot with specific descriptions — the worker's next round sees this as context.

$(loop_context_tips reflect)
EOF
}

gate_prompt() {
  local agent_history=$(fmt_agent_history)
  local diff_block=$(fmt_agent_diff_block)
  local files_block=$(fmt_files_block)
  local verify_block=$(fmt_verify_block)
  local file_contents_block=$(build_file_contents_block)
  local delta_block=$(fmt_worker_delta_block)
  cat <<EOF
You are the GATE-CHECK agent. A worker agent claims it completed this task:

<task>
$TASK
</task>

FULL AGENT HISTORY (every worker and gate-check message from all prior rounds, in chronological order — the worker's latest round is the most recent entry):
<agent_history>
$agent_history
</agent_history>
${diff_block:+
$diff_block}
${files_block:+
$files_block}
${verify_block:+
$verify_block}
${file_contents_block:+
$file_contents_block}
${delta_block:+
$delta_block}

VERIFICATION PROCEDURE — execute EVERY step, do not skip any:

$SHELL_RULES

CRITICAL: Do NOT read, cat, sed, or open any file whose contents appear in XML blocks above (<file_content>, <diff>, <verify_output>) — not even partial or targeted reads. These reflect the current contents on disk at agent start and will not change during your runtime unless you change them (which you should not). Re-reading them in any form wastes time and context. Only read files NOT already provided when you need additional context.


1. REQUIREMENT DECOMPOSITION: Re-read the original task word by word. Break it into an explicit numbered checklist of every individual ask, requirement, constraint, and implicit expectation. Do not paraphrase — use the original wording. Then verify EACH item against the actual code. Mark each PASS or FAIL with evidence (file path + line or snippet).

2. FILE-BY-FILE AUDIT: Start from the diff above. For each changed file, verify the changes are syntactically valid, logically correct, and consistent with the rest of the file. Only use \`cat -n\` to read a full file when the diff alone is insufficient to verify correctness (e.g., you need surrounding context). Do not trust the worker's summary — inspect the actual changes.

3. CASCADING EFFECTS: For every change, trace ALL references. Check:
   - Imports/exports — are all updated?
   - Call sites — do all callers pass correct arguments?
   - Types/interfaces — are signatures consistent across the codebase?
   - Configuration files — do they reflect the changes?
   - Documentation/comments — are they accurate post-change?
   - Naming — is it consistent everywhere (no old names lingering)?
   If ANY follow-on update is missing, that is a FAIL.

4. REGRESSION CHECK: Read surrounding code in every modified file. Do the changes conflict with, break, or subtly alter existing behavior? Check edge cases and error paths.

5. COMPLETENESS SWEEP:
   - No TODOs, FIXMEs, or placeholder code left behind
   - No commented-out old code that should have been removed
   - No orphaned imports, variables, functions, or files
   - No partial implementations (function declared but not wired up)
   - No hardcoded values that should be configurable

6. OMISSION CHECK: Step back from the checklist. Is there anything the task OBVIOUSLY needs that wasn't explicitly stated but would be expected by a competent developer? Missing error handling, missing validation, missing edge cases, missing logging — if it's an obvious omission, it's a FAIL.

DEFAULT STANCE: Assume the work is incomplete until proven otherwise. Your job is to find problems, not to rubber-stamp. When in doubt, FAIL. A false rejection costs one more worker round. A false approval ships broken code.

EFFICIENCY: The <worker_delta> block above (if present) lists files changed since the last reflection/gate cycle. For files NOT in that list, your prior verification still holds — do not re-verify them. Focus exclusively on changed/new files and any previously-failed items. If no delta block is present, this is the first verification cycle — verify everything.

DECISION:
- ONLY if every single ask is done AND no follow-on codebase updates are missing, write EXACTLY "$GATE_PASS_TOKEN" to "$GATE_SIGNAL". The file must contain this token and nothing else — no explanation, no extra text.
- Otherwise, write EXACTLY "$GATE_FAIL_TOKEN" to "$GATE_SIGNAL" (token only, nothing else).
- ALWAYS write a concise summary of your findings to "$AGENT_MSG" (overwrite, not append). Include: what was checked, what passed, what failed. On failure, list EVERY unresolved item with specific file paths and descriptions — the worker's next round sees this file as context.

$(loop_context_tips gate)
EOF
}

summary_prompt() {
  local agent_history=$(fmt_agent_history)
  cat <<EOF
You are the SUMMARY agent. The task below was completed in $round round(s) by a worker/gate loop.

TASK:
<task>
$TASK
</task>

FULL AGENT HISTORY:
<agent_history>
$agent_history
</agent_history>

Write a concise, human-readable summary to "$RALPH_SUMMARY". Include:
- What was done (key changes, not a play-by-play of rounds)
- Every file created, modified, or deleted (full paths)
- Any notable decisions, trade-offs, or caveats
- If the gate rejected work at any point, briefly note what was caught and fixed

Keep it dense and scannable. No preamble. Do not write to any other file.
EOF
}

# ─── Main loop ────────────────────────────────────────────────────────────────

mkdir -p .ralph
mkdir -p "$RALPH_STATE"
setup_git_wrapper
cleanup
if ! $WORKTREE; then
  if [[ -f "$RALPH_LOCK" ]] && kill -0 "$(<"$RALPH_LOCK")" 2>/dev/null; then
    echo "Error: another ralph-loop is already running (PID $(<"$RALPH_LOCK"))." >&2
    exit 1
  fi
  echo $$ > "$RALPH_LOCK"
fi
trap cleanup EXIT
trap on_interrupt INT

if $CONTINUE; then
  if [[ ! -f "$AGENT_LOG" ]]; then
    echo "Error: no prior run found ($AGENT_LOG missing). Run without --continue first." >&2
    exit 1
  fi
  PRIOR_TASK=""
  [[ -f "$RALPH_TASK" ]] && PRIOR_TASK=$(<"$RALPH_TASK")
  TASK="${PRIOR_TASK:-<no prior task — see agent history for context>}

ADDITIONAL INSTRUCTIONS (--continue):
$TASK"
else
  setup_worktree
fi
# Ensure prompts dir exists in working directory (may be worktree)
mkdir -p "$RALPH_STATE/prompts"

if $PLAN_MODE; then
  TASK="PLAN-ONLY MODE: You MAY read any code files to understand the codebase, but do NOT create, modify, or delete any project files except $PWD/plan.md. Your sole output is a markdown plan document at $PWD/plan.md. When writing anything to the plan, do so in sections. Keep each section focused and concise — break large sections into smaller subsections. Research the codebase as needed, then write a detailed implementation plan for the following task:

$TASK"
fi

echo "$TASK" > "$RALPH_TASK"
snapshot_pre
build_diff
LOOP_START=$SECONDS

round=0
$CONTINUE && [[ -f "$RALPH_ROUND_FILE" ]] && round=$(<"$RALPH_ROUND_FILE")
while true; do
  # --- Worker phase: loop until worker signals done ---
  while true; do
    (( round++ )) || true
    echo "$round" > "$RALPH_ROUND_FILE"
    echo "\n══════════════════════════════════════"
    echo "  RALPH LOOP — Worker Round $round"
    echo "══════════════════════════════════════\n"

    rm -f "$WORKER_SIGNAL" "$AGENT_MSG"
    save_pre_round_manifest
    run_agent "worker" "Worker Round $round" "$(worker_prompt)"
    extract_worker_files
    if [[ -f "$AGENT_MSG" ]]; then
      { echo "── Worker Round $round ──"; cat "$AGENT_MSG"; } | tee -a "$AGENT_LOG" >> "$WORKER_LOG"
    fi
    build_diff
    stage_new_untracked

    if check_signal "$WORKER_SIGNAL" "$WORKER_TOKEN"; then
      echo "\n✓ Worker signaled completion. Running gate-check...\n"
      break
    fi
    echo "\n⏳ Worker did not signal completion. Continuing...\n"
  done

  # --- Verify phase ---
  rm -f "$VERIFY_OUTPUT"
  if [[ -n "$VERIFY_CMD" ]]; then
    echo "\n── Verify: running verify-cmd... ──\n"
    local verify_exit=0 t0=$SECONDS
    set +e
    zsh -c "$VERIFY_CMD" 2>&1 | tee "$VERIFY_OUTPUT"
    verify_exit=${pipestatus[1]}
    set -e
    log_timing "Verify" $((SECONDS - t0))
    { echo "── Verify (exit $verify_exit) ──"; cat "$VERIFY_OUTPUT"; } | tee -a "$AGENT_LOG" >> "$GATE_LOG"
  fi

  # --- Reflection phase ---
  rm -f "$REFLECT_SIGNAL" "$AGENT_MSG"
  echo "\n── Reflection: considering all avenues... ──\n"
  run_agent "reflection" "Reflection" "$(reflect_prompt)"
  if [[ -f "$AGENT_MSG" ]]; then
    { echo "── Reflection ──"; cat "$AGENT_MSG"; } | tee -a "$AGENT_LOG" >> "$GATE_LOG"
  fi

  if check_signal "$REFLECT_SIGNAL" "$REFLECT_FAIL_TOKEN"; then
    save_verified_manifest
    echo "\n✗ Reflection found unexplored avenues. Sending back to worker...\n"
    continue
  fi
  echo "\n✓ Reflection passed. Running gate-check...\n"

  # --- Gate phase ---
  rm -f "$GATE_SIGNAL" "$AGENT_MSG"
  run_agent "gate" "Gate-Check" "$(gate_prompt)"
  if [[ -f "$AGENT_MSG" ]]; then
    { echo "── Gate-Check ──"; cat "$AGENT_MSG"; } | tee -a "$AGENT_LOG" >> "$GATE_LOG"
  fi
  save_verified_manifest

  if check_signal "$GATE_SIGNAL" "$GATE_PASS_TOKEN"; then
    echo "\n══════════════════════════════════════"
    echo "  ✓ RALPH LOOP COMPLETE — Round $round"
    echo "══════════════════════════════════════\n"

    echo "📝 Generating summary...\n"
    run_agent "summary" "Summary" "$(summary_prompt)"
    if [[ -f "$RALPH_SUMMARY" ]]; then
      echo "\n📝 Summary ($RALPH_SUMMARY):\n"
      cat "$RALPH_SUMMARY"
      echo ""
    fi

    snapshot_post
    cleanup_worktree
    log_timing "Total" $((SECONDS - LOOP_START))
    exit 0
  fi

  echo "\n✗ Gate rejected. Sending back to worker...\n"
done
