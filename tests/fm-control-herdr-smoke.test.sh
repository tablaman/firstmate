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
# The first case begins with no registered agent, where interrupt must refuse,
# then plants a stale idle/done registration on a lone shell: exit must say
# already-stopped, relaunch must resurrect the same pane/worktree, and
# interrupt on the relaunched agent must deliver with the agent-alive proof.
# The second case keeps an idle registration on a pane running a non-shell
# foreground command, so exit must refuse rather than pretending the agent
# stopped.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-control-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
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
WT2="$SCRATCH/wt2"
git -C "$PROJ" worktree add --quiet -b hsmoke-live "$WT2"

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

# --- no registered agent: the endpoint exists but hosts no agent ------------

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- stale settled registration on a lone shell: exit is already-stopped, and
# relaunch reuses the same pane/worktree -------------------------------------

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

OUT=$(run_control hsmoke relaunch --note "stale shell recovered in place") \
  || fail "relaunch against the stale shell should succeed in place: $OUT"
case "$OUT" in
  *"relaunched hsmoke harness=claude"*"backend=herdr"*"endpoint=$SESSION:$PANE_ID"*"worktree=$WT"*) : ;;
  *) fail "relaunch should reuse the same pane and worktree, got: $OUT" ;;
esac
STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "the relaunched pane should be classified alive, got '$STATE'"

herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: relaunch reuses the same pane and worktree, and the endpoint/local copy remain"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against the relaunched agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "the relaunched agent must survive its interrupt key, got '$STATE'"
pass "real herdr: interrupt delivers the harness's key to the relaunched agent and proves it survived"

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

OUT=$(fm_backend_herdr_send_text_line "$SESSION:$PANE2_ID" "sleep 60") \
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
