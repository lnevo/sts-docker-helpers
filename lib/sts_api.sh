# shellcheck shell=bash
# Client for the STS REST API v1. Source this file (lib/paths.sh must be sourced
# first so BACKUPS_DIR is known; the token falls back to it).
#
#   sts_api METHOD PATH [JSON]   print the response "data" as JSON; exit 1 + message on error
#   sts_api_raw METHOD PATH [JSON]  print the whole envelope (data + meta)
#   sts_api_get_field JSON KEY   extract a (dotted) key from JSON text
#   sts_task_wait ID [TIMEOUT]   poll /tasks/ID, stream new log lines, 1 when failed
#   sts_session_nbr              current session number from GET /session
#   sts_api_guard                print the target once and refuse a wrong stack
#
# Environment: STS_API_URL, STS_API_TOKEN, STS_API_TOKEN_FILE, STS_EXPECT_STACK.
# Base URL default: COMPOSE_PROJECT_NAME=sts-sandbox -> :8981, otherwise :8980.

sts_api_base() {
  if [[ -n "${STS_API_URL:-}" ]]; then
    printf '%s' "${STS_API_URL%/}"
  elif [[ "${COMPOSE_PROJECT_NAME:-}" == "sts-sandbox" ]]; then
    printf '%s' "http://localhost:8981/sts/api/v1"
  else
    printf '%s' "http://localhost:8980/sts/api/v1"
  fi
}

sts_api_expected_stack() {
  if [[ -n "${STS_EXPECT_STACK:-}" ]]; then
    printf '%s' "${STS_EXPECT_STACK}"
  elif [[ "${COMPOSE_PROJECT_NAME:-}" == "sts-sandbox" ]]; then
    printf '%s' "sandbox"
  else
    printf '%s' "live"
  fi
}

sts_api_token() {
  if [[ -n "${STS_API_TOKEN:-}" ]]; then
    printf '%s' "${STS_API_TOKEN}"
    return 0
  fi
  local file="${STS_API_TOKEN_FILE:-}"
  if [[ -z "${file}" && -n "${BACKUPS_DIR:-}" ]]; then
    file="$(dirname "${BACKUPS_DIR}")/config/bootstrap_admin.token"
  fi
  if [[ -n "${file}" && -r "${file}" ]]; then
    tr -d '[:space:]' < "${file}"
  fi
}

sts_api_get_field() {
  local json="$1" key="$2"
  printf '%s' "${json}" | python3 -c '
import json, sys
v = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    v = v[int(part)] if isinstance(v, list) else v.get(part) if isinstance(v, dict) else None
    if v is None:
        break
if v is None:
    v = ""
print(json.dumps(v) if isinstance(v, (dict, list)) else v)
' "${key}"
}

# One HTTP call. Sets STS_API_BODY and STS_API_HTTP; no guard.
_sts_api_call() {
  local method="$1" path="$2" body="${3:-}"
  local base token tmp
  base="$(sts_api_base)"
  token="$(sts_api_token)"
  tmp="$(mktemp)"
  local args=(-sS -o "${tmp}" -w '%{http_code}' -X "${method}" -H 'Accept: application/json')
  [[ -n "${token}" ]] && args+=(-H "Authorization: Bearer ${token}")
  if [[ -n "${body}" ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary "${body}")
  fi
  if ! STS_API_HTTP="$(curl "${args[@]}" "${base}${path}" 2>"${tmp}.err")"; then
    echo "STS API unreachable at ${base}: $(cat "${tmp}.err")" >&2
    rm -f "${tmp}" "${tmp}.err"
    return 1
  fi
  STS_API_BODY="$(cat "${tmp}")"
  rm -f "${tmp}" "${tmp}.err"
}

sts_api_guard() {
  [[ "${_STS_API_GUARDED:-}" == "1" ]] && return 0
  local expected actual
  expected="$(sts_api_expected_stack)"
  _sts_api_call GET /health || return 1
  actual="$(sts_api_get_field "$(printf '%s' "${STS_API_BODY}" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("data", {})))' 2>/dev/null || echo '{}')" stack)"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "REFUSING: ${STS_API_URL:-$(sts_api_base)} is stack '${actual:-unknown}' but this run expects '${expected}'." >&2
    echo "Check COMPOSE_PROJECT_NAME / STS_API_URL / STS_EXPECT_STACK." >&2
    return 1
  fi
  if [[ "${_STS_API_ANNOUNCED:-}" != "1" ]]; then
    echo "==> STS API target: ${actual} ($(sts_api_base))" >&2
    export _STS_API_ANNOUNCED=1
  fi
  _STS_API_GUARDED=1
}

# sts_api_raw METHOD PATH [JSON]: whole envelope on stdout.
sts_api_raw() {
  local method="$1" path="$2" body="${3:-}"
  if [[ "${method}" != "GET" ]]; then
    sts_api_guard || return 1
  fi
  _sts_api_call "${method}" "${path}" "${body}" || return 1
  if [[ "${STS_API_HTTP}" -ge 400 || "${STS_API_HTTP}" -eq 0 ]]; then
    printf '%s' "${STS_API_BODY}" | python3 -c '
import json, sys
http, method, path = sys.argv[1:4]
try:
    e = json.load(sys.stdin)["error"]
    print("STS API %s %s -> HTTP %s %s: %s" % (method, path, http, e.get("code"), e.get("message")), file=sys.stderr)
except Exception:
    print("STS API %s %s -> HTTP %s (no error envelope)" % (method, path, http), file=sys.stderr)
' "${STS_API_HTTP}" "${method}" "${path}"
    return 1
  fi
  printf '%s\n' "${STS_API_BODY}"
}

sts_api() {
  local raw
  raw="$(sts_api_raw "$@")" || return 1
  printf '%s' "${raw}" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("data")))'
}

sts_session_nbr() {
  local out
  out="$(sts_api GET /session)" || return 1
  sts_api_get_field "${out}" session_nbr
}

# sts_task_wait ID [TIMEOUT_SECONDS]: prints new log lines as they appear (timestamps
# stripped unless STS_TASK_KEEP_TS=1; nothing printed when STS_TASK_QUIET=1; lines matching
# the ERE in STS_TASK_DROP are skipped).
sts_task_wait() {
  local id="$1" timeout="${2:-3600}"
  local start=$SECONDS shown=0 raw status state
  state="$(mktemp)"
  while :; do
    raw="$(sts_api GET "/tasks/${id}?log=5000")" || { rm -f "${state}"; return 1; }
    printf '%s' "${raw}" | python3 -c '
import json, sys
t = json.load(sys.stdin)
shown = int(sys.argv[1])
log = t.get("log") or []
if isinstance(log, str):
    log = log.splitlines()
import os, re
for line in log[shown:]:
    if not os.environ.get("STS_TASK_KEEP_TS"):
        line = re.sub(r"^\[\d\d:\d\d:\d\d\] ", "", line)
    drop = os.environ.get("STS_TASK_DROP")
    if drop and re.search(drop, line):
        continue
    if not os.environ.get("STS_TASK_QUIET"):
        print(line)
open(sys.argv[2], "w").write(str(len(log)))
' "${shown}" "${state}"
    shown="$(cat "${state}")"
    status="$(sts_api_get_field "${raw}" status)"
    case "${status}" in
      succeeded) rm -f "${state}"; return 0 ;;
      failed)
        rm -f "${state}"
        echo "Task ${id} failed: $(sts_api_get_field "${raw}" error)" >&2
        return 1 ;;
    esac
    if (( SECONDS - start > timeout )); then
      rm -f "${state}"
      echo "Task ${id} still ${status} after ${timeout}s" >&2
      return 1
    fi
    sleep 1
  done
}

# sts_task_run METHOD PATH [JSON]: start a task route and wait for it; prints the task result JSON via STS_TASK_RESULT.
sts_task_run() {
  local out id
  out="$(sts_api "$@")" || return 1
  id="$(sts_api_get_field "${out}" task_id)"
  [[ -n "${id}" ]] || { echo "No task_id in response: ${out}" >&2; return 1; }
  # Set for callers: the task id and the final task record.
  # shellcheck disable=SC2034
  STS_TASK_ID="${id}"
  sts_task_wait "${id}"
  local rc=$?
  # shellcheck disable=SC2034
  STS_TASK_RESULT="$(sts_api GET "/tasks/${id}" 2>/dev/null || true)"
  return "${rc}"
}
