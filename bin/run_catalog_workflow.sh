#!/usr/bin/env bash
# Drive a saved workflow through session_run_recipe via the REST API (correct phased
# switch-list engine). Defaults to the editor's ACTIVE workflow so it runs the
# same recipe as the app UI. Pass a workflow file/name to override.
#
# Usage:
#   run_catalog_workflow.sh                         # active saved workflow
#   run_catalog_workflow.sh start_session.workflow.json
#   run_catalog_workflow.sh /abs/path/to/workflow.json
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

# shellcheck source=../lib/sts_api.sh
source "${_script_home}/../lib/sts_api.sh"
sts_api_guard || exit 1

WORKFLOW_ARG="${1:-}"
EDITOR_DIR="${BACKUPS_DIR}/session_editor"
if [[ -z "${WORKFLOW_ARG}" ]]; then
  # The editor's ACTIVE workflow: the one the app UI runs.
  WORKFLOW_NAME="$(sts_api_get_field "$(sts_api GET /workflows)" active)"
  [[ -n "${WORKFLOW_NAME}" ]] || { echo "No active workflow; pass a workflow name or file." >&2; exit 1; }
elif [[ -f "${WORKFLOW_ARG}" ]]; then
  # Host path: save it through the API (PUT /workflows/{name}) unless it already is the saved file.
  WORKFLOW_NAME="$(basename "${WORKFLOW_ARG}")"
  if [[ "$(cd "$(dirname "${WORKFLOW_ARG}")" && pwd -P)" != "$(cd "${EDITOR_DIR}" 2>/dev/null && pwd -P)" ]]; then
    recipe_body="$(mktemp)"
    python3 -c 'import json,sys; print(json.dumps({"recipe": json.load(open(sys.argv[1]))}))' "${WORKFLOW_ARG}" > "${recipe_body}"
    sts_api PUT "/workflows/${WORKFLOW_NAME}" "@${recipe_body}" >/dev/null
    rm -f "${recipe_body}"
  fi
else
  # Bare name of a saved workflow.
  WORKFLOW_NAME="${WORKFLOW_ARG}"
fi

# STS_SIM_SEED (optional) makes the run reproducible.
BODY='{}'
if [[ -n "${STS_SIM_SEED:-}" ]]; then
  BODY="{\"seed\":${STS_SIM_SEED}}"
  echo "STS_SIM_SEED: mt_srand(${STS_SIM_SEED})" >&2
fi

rc=0
STS_TASK_QUIET=1 sts_task_run POST "/workflows/${WORKFLOW_NAME}/run" "${BODY}" || rc=$?
SESSION="$(sts_session_nbr)"
MANIFEST="$(sts_api GET "/sessions/${SESSION}" 2>/dev/null || echo '{}')"

# Report in the format of run_catalog_workflow.php.
printf '%s\n%s\n' "${STS_TASK_RESULT}" "${MANIFEST}" | python3 -c '
import json, sys
name = sys.argv[1]
task = json.loads(sys.stdin.readline())
manifest = json.loads(sys.stdin.readline() or "{}") or {}
out = (task.get("result") or {}).get("output") or {}
cycles = out.get("cycles") or [{}]
phases = [p for p in (manifest.get("manifest") or {}).get("phases", []) if "waybills" in p]
print("Catalog workflow run")
print("  Workflow: /var/www/html/sts/backups/session_editor/%s" % name)
print("  Session:  %s" % (cycles[-1].get("session") or manifest.get("session") or "?"))
print("  Steps:    %s" % out.get("steps", "?"))
print("  Phases:   %s" % cycles[-1].get("phases", 0))
print("  Control:  %s" % out.get("control", 0))
print("  Dispatch: %s" % out.get("dispatched", 0))
print("  Skipped:  %s" % out.get("skipped", 0))
if phases:
    print("Switch-list phases:")
    for p in phases:
        cars = int((p.get("waybills") or {}).get("count") or 0)
        print("  phase %-2s (step %-3s) %-14s %d car(s)%s" % (p.get("phase"), p.get("step"), ",".join(p.get("jobs") or []), cars, "  <== EMPTY" if cars == 0 else ""))
errors = out.get("errors") or ([task["error"]] if task.get("error") else [])
if errors:
    print("  Errors:   %d" % len(errors))
    for e in errors:
        print("    - %s" % e)
    sys.exit(1)
print("  Status:   OK")
' "${WORKFLOW_NAME}" || rc=1
exit "${rc}"
