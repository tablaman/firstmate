#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from herdr's own agent registry.
#
# The smoke runs five isolated real-Herdr cases: interrupt refusal with no
# agent, stale idle-registration exit, relaunch reuse, nested-shell relaunch
# interrupt death, and live non-shell exit refusal.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr, jq, or claude is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v claude >/dev/null 2>&1 || { echo "skip: claude not found"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-control-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  trap - EXIT
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT

# The lone-shell legs require the pane's interactive shell to come up bare,
# and pane shells inherit the lab server's environment, which inherits this
# test's. An operator terminal-integration shim (fig/Amazon Q/kiro-cli's
# kiro-cli-term) execs the pane's zsh into a pty wrapper with a child shell,
# which the strict lone-idle-shell proof then correctly refuses to collapse -
# so whether legs 2-5 can even observe the recovery behavior would depend on
# whether the terminal that launched the test was itself already wrapped
# (those markers suppress re-wrapping). Export the integration's own
# "already wrapped / launched by the tool" markers so the lab's pane shells
# deterministically skip the shim regardless of the invoking terminal.
export PROCESS_LAUNCHED_BY_Q=1
export Q_TERM=1

fm_herdr_lab_provision "$SESSION" || fail "could not provision isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"
WT=$(cd "$WT" && pwd -P)
WT2="$SCRATCH/wt2"
git -C "$PROJ" worktree add --quiet -b hsmoke-live "$WT2"
WT2=$(cd "$WT2" && pwd -P)

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 FM_CONTROL_LAUNCH_WAIT=10 FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=30 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: interrupt refuses --------------------------------

OUT=$(run_control hsmoke interrupt); RC=$?
[ "$RC" -eq 1 ] || fail "interrupt against the idle task should refuse, got rc=$RC: $OUT"
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "interrupt should refuse when herdr's own agent registry reports no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- stale settled registration on a lone shell: exit is already-stopped ----

herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a stale agent on the task pane"
sleep 1

OUT=$(run_control hsmoke exit) || fail "exit against a stale-shell herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "a stale-shell herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a stale idle registration over a lone shell is already-stopped"

# --- relaunch reuses the same pane/worktree ---------------------------------

OUT=$(run_control hsmoke relaunch --note "stale shell recovered in place") \
  || fail "relaunch against the stale shell should succeed in place: $OUT"
case "$OUT" in
  *"relaunched hsmoke harness=claude"*"backend=herdr"*"endpoint=$SESSION:$PANE_ID"*"worktree=$WT"*) : ;;
  *) fail "relaunch should reuse the same pane and worktree, got: $OUT" ;;
esac
STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "the relaunched pane should be classified alive, got '$STATE'"
CUR_PATH=$(fm_backend_herdr_current_path "$SESSION:$PANE_ID")
[ "$CUR_PATH" = "$WT" ] || fail "the relaunched pane should still read the task worktree path, got: $CUR_PATH"
sleep 1
INFO=
for _ in 1 2 3 4 5 6; do
  INFO=$(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null) && break
  sleep 0.5
done
[ -n "$INFO" ] || fail "the relaunched pane should still be readable as a real Herdr process-info target"
SHELL_PID=$(printf '%s' "$INFO" | jq -r '.result.process_info.shell_pid // empty')
FG_PID=$(printf '%s' "$INFO" | jq -r '.result.process_info.foreground_processes[0].pid // empty')
[ -n "$SHELL_PID" ] && [ -n "$FG_PID" ] || fail "the relaunched pane did not report both shell and foreground pids: $INFO"
[ "$SHELL_PID" != "$FG_PID" ] || fail "the relaunched pane should be the nested-shell worktree shape, got shell_pid=$SHELL_PID foreground_pid=$FG_PID"
pass "real herdr: relaunch reuses the same pane and worktree, and the endpoint/local copy remain"

# --- nested-shell relaunch interrupt reports the relaunched agent's death --

OUT=$(run_control hsmoke interrupt); RC=$?
[ "$RC" -eq 1 ] || fail "interrupt against the relaunched agent should refuse, got rc=$RC: $OUT"
case "$OUT" in
  *"agent is 'dead' after its interrupt key"*) : ;;
  *) fail "interrupt on the relaunched agent should report that it died, got: $OUT" ;;
esac
STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] || fail "the relaunched nested-shell pane should be dead after interrupt, got '$STATE'"
pass "real herdr: interrupt after relaunch reaches the relaunched agent and reports death"

# --- a live non-shell foreground process still refuses exit ------------------

TASK2_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke-live" "$WT2") \
  || fail "create_task for the non-shell refusal case failed"
read -r TAB2_ID PANE2_ID <<EOF
$TASK2_IDS
EOF
[ -n "$TAB2_ID" ] && [ -n "$PANE2_ID" ] || fail "the non-shell refusal task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE2_ID"
  echo "endpoint_task_id=hsmoke-live"
  echo "worktree=$WT2"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB2_ID"
  echo "herdr_pane_id=$PANE2_ID"
} > "$HOME_DIR/state/hsmoke-live.meta"

herdr pane report-agent "$PANE2_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register the live non-shell refusal agent"
sleep 1

# The stand-in process must outlast the whole exit verb, not just its final
# postcondition wait: exit's delivery confirmation (Enter retries, native
# agent-state waits, composer verdicts, and the idle-branch shell proof's own
# retry budget on every classification) can take over a minute against a live
# server. A sleep that expires mid-verb collapses the pane to a genuine lone
# idle shell, so a later 'stopped' would be a correct observation of the wrong
# scenario rather than the refusal this leg pins.
OUT=$(fm_backend_herdr_send_text_line "$SESSION:$PANE2_ID" "sleep 600") \
  || fail "could not start the non-shell foreground process"
sleep 0.5
STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE2_ID")
[ "$STATE" = alive ] || fail "the non-shell foreground process should stay alive, got '$STATE'"

if OUT=$(run_control hsmoke-live exit 2>&1); then
  fail "exit should fail closed when the non-shell foreground process does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the non-shell exit failure should say the agent did not stop, got: $OUT" ;;
esac
pass "real herdr: a live non-shell foreground process stays live and refuses exit"
