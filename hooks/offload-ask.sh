#!/usr/bin/env bash
# offload — PreToolUse hook, matched on the ExitPlanMode tool.
#
# Blocks the first attempt to exit plan mode in a session and tells Claude to
# ask the user whether to offload execution to agy subagents before showing
# the plan for approval. The second attempt in the same session is let
# through unchanged, so answering the question does not loop.
#
# Requires jq. If jq is missing, this hook fails open — it allows the tool
# call through with no question, so a missing dependency never blocks plan
# mode.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo '{}'
  exit 0
fi

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"

# Defensive: the settings.json matcher already restricts this hook to
# ExitPlanMode, but a hook script should not assume its caller is correct.
if [ "$tool_name" != "ExitPlanMode" ] || [ -z "$session_id" ]; then
  echo '{}'
  exit 0
fi

marker_dir="${TMPDIR:-/tmp}/offload-skill"
mkdir -p "$marker_dir"
marker="$marker_dir/${session_id}.asked"

# Already asked once this session — let this and every later ExitPlanMode
# call through with no interruption.
if [ -e "$marker" ]; then
  echo '{}'
  exit 0
fi

touch "$marker"

reason='Before calling ExitPlanMode, ask the user with AskUserQuestion: "Offload execution to agy subagents instead of running it here?" If they say yes, revise the plan file to add an offload dispatch spec first — for each task: a provisional description for scouting, one gate (a machine-gate command a gate-author worker will author and you will red-check and read, or written diff-review criteria a reviewer worker will judge), and any frozen paths — following the offload skill. If they say no, or a plan is not the right fit for offloading, leave the plan as it is. Then call ExitPlanMode again either way.'

jq -n --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
