#!/usr/bin/env bash
# Sweep order-generation gate (max_unfilled) and empty-reposition percent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SEED_DIR="${ROOT}/sts-docker-helpers/seed"
BACKUP="${ROOT}/sts-backups/hart_seed"
WORKFLOW_SRC="${ROOT}/sts-backups/session_editor/start_session.workflow.json"
WORKFLOW_TMP="${ROOT}/sts-backups/session_editor/_gate_sweep.workflow.json"
COMPOSE="${ROOT}/sts-docker/docker-compose.yml"
ROUNDS="${1:-3}"
SESSIONS="${2:-20}"
LOG_DIR="${ROOT}/sts-backups/session_editor"
LOG="${LOG_DIR}/gate_reposition_sweep_$(date +%Y%m%d_%H%M%S).log"

GATES=(20 30 35)
REPOSITIONS=(50 65 80)

WEB_CID="$(docker compose -f "${COMPOSE}" --profile build ps -q web)"
if [[ -z "${WEB_CID}" ]]; then
  echo "STS web container is not running." >&2
  exit 1
fi

deploy_runtime() {
  for f in session_helpers.php master_switchlist_helpers.php operational_steps_catalog.php \
    track_scale_helpers.php warm_start_helpers.php _track_scale_10x10.php; do
    docker cp "${ROOT}/sts-docker/sts/${f}" "${WEB_CID}:/var/www/html/sts/${f}"
  done
}

patch_workflow() {
  local gate="$1"
  local repo_pct="$2"
  python3 - <<PY
import json
from pathlib import Path
src = Path("${WORKFLOW_SRC}")
dst = Path("${WORKFLOW_TMP}")
recipe = json.loads(src.read_text(encoding="utf-8"))
for step in recipe.get("steps", []):
    fn = step.get("function", "")
    params = step.setdefault("params", {})
    if fn == "generate_orders" and not (params.get("shipment") or "").strip():
        params["max_unfilled"] = "${gate}"
    if fn == "reposition_empties":
        params["percent"] = "${repo_pct}"
dst.write_text(json.dumps(recipe, indent=4) + "\n", encoding="utf-8")
PY
  docker cp "${WORKFLOW_TMP}" \
    "${WEB_CID}:/var/www/html/sts/backups/session_editor/start_session.workflow.json"
}

echo "==> Gate / reposition sweep" | tee "${LOG}"
echo "    ${ROUNDS} seeds x ${SESSIONS} sessions" | tee -a "${LOG}"
echo "    Gates: ${GATES[*]}  Reposition %: ${REPOSITIONS[*]}" | tee -a "${LOG}"
echo | tee -a "${LOG}"

echo "==> Generate + restore hart_seed (traffic_mult from config, yard balance on)" | tee -a "${LOG}"
python3 "${SEED_DIR}/generate_hart_seed.py" --output "${BACKUP}" >> "${LOG}" 2>&1
"${ROOT}/sts-docker-helpers/bin/apply_hart_seed.sh" --merge-fleet >> "${LOG}" 2>&1
deploy_runtime

printf "%-6s %-5s | %-5s %-5s %-5s %-5s | %-5s %-5s | %-6s %-6s %-6s | %-4s %-4s | %s\n" \
  "Gate" "Repo%" "Dem" "Scul" "Sth" "Nv" "Unfl" "Open" "CK1pu" "D749pu" "NVLpu" "CKls" "D7ls" \
  | tee -a "${LOG}"
printf "%s\n" "$(printf '%.0s-' {1..100})" | tee -a "${LOG}"

BEST_SCORE=-1
BEST_LINE=""

for gate in "${GATES[@]}"; do
  for repo in "${REPOSITIONS[@]}"; do
    echo "==> gate=${gate} reposition=${repo}%" | tee -a "${LOG}"
    patch_workflow "${gate}" "${repo}"

    OUT="$(docker exec "${WEB_CID}" php /var/www/html/sts/_track_scale_10x10.php \
      /var/www/html/sts/backups/session_editor/start_session.workflow.json \
      "${ROUNDS}" "${SESSIONS}" 2>&1)"
    echo "${OUT}" >> "${LOG}"

    AVG_LINE="$(echo "${OUT}" | grep '^AVG' || true)"
    if [[ -z "${AVG_LINE}" ]]; then
      echo "WARN: no AVG for gate=${gate} repo=${repo}" | tee -a "${LOG}"
      continue
    fi

    dem="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}' | awk '{print $1}')"
    scul="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}' | awk '{print $2}')"
    sth="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}' | awk '{print $3}')"
    nv="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}' | awk '{print $4}')"
    unfl="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}' | awk '{print $1}')"
    open="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}' | awk '{print $2}')"
    ck1="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$6); print $6}' | awk '{print $1}')"
    d749="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$6); print $6}' | awk '{print $2}')"
    nvl="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$6); print $6}' | awk '{print $3}')"
    ckls="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$7); print $7}' | awk '{print $1}')"
    d7ls="$(echo "${AVG_LINE}" | awk -F'|' '{gsub(/^ +| +$/,"",$7); print $7}' | awk '{print $2}')"
    ok="$(echo "${AVG_LINE}" | grep -oE '[0-9]+/[0-9]+ ok' || echo '?')"

    score="$(python3 - <<PY
unfl=float("${unfl}")
ck1=float("${ck1}")
d749=float("${d749}")
nvl=float("${nvl}")
ckls=float("${ckls}")
d7ls=float("${d7ls}")
ok="${ok}"
ok_n=0
if "/" in ok:
    ok_n=int(ok.split("/")[0])
# Higher movement + lists, lower backlog, more ok rounds.
print(round((ck1+d749+nvl)/10 + ckls + d7ls*2 - unfl*1.5 + ok_n*25, 1))
PY
)"

    line="$(printf "%-6s %-5s | %-5s %-5s %-5s %-5s | %-5s %-5s | %-6s %-6s %-6s | %-4s %-4s | score=%s %s" \
      "${gate}" "${repo}" "${dem}" "${scul}" "${sth}" "${nv}" "${unfl}" "${open}" \
      "${ck1}" "${d749}" "${nvl}" "${ckls}" "${d7ls}" "${score}" "${ok}")"
    echo "${line}" | tee -a "${LOG}"

    better="$(python3 - <<PY
print(1 if float("${score}") > float("${BEST_SCORE}") else 0)
PY
)"
    if [[ "${better}" -eq 1 ]]; then
      BEST_SCORE="${score}"
      BEST_LINE="${line}"
      BEST_GATE="${gate}"
      BEST_REPO="${repo}"
    fi
    echo | tee -a "${LOG}"
  done
done

echo "==> Best mix: gate=${BEST_GATE:-?} reposition=${BEST_REPO:-?}% (score=${BEST_SCORE})" | tee -a "${LOG}"
echo "${BEST_LINE:-}" | tee -a "${LOG}"

# Apply winner to source workflow + config defaults.
if [[ -n "${BEST_GATE:-}" && -n "${BEST_REPO:-}" ]]; then
  patch_workflow "${BEST_GATE}" "${BEST_REPO}"
  python3 - <<PY
import json
from pathlib import Path
wf = Path("${WORKFLOW_SRC}")
recipe = json.loads(wf.read_text(encoding="utf-8"))
for step in recipe.get("steps", []):
    fn = step.get("function", "")
    params = step.setdefault("params", {})
    if fn == "generate_orders" and not (params.get("shipment") or "").strip():
        params["max_unfilled"] = "${BEST_GATE}"
    if fn == "reposition_empties":
        params["percent"] = "${BEST_REPO}"
wf.write_text(json.dumps(recipe, indent=4) + "\n", encoding="utf-8")

cfg_path = Path("${SEED_DIR}/hart_seed_config.json")
cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
ws = cfg.setdefault("warm_start", {})
ws["max_unfilled_before_generate"] = int("${BEST_GATE}")
ws["reposition_fraction"] = round(int("${BEST_REPO}") / 100.0, 2)
partial = ws.setdefault("partial", {})
partial["reposition"] = ws["reposition_fraction"]
cfg_path.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")
PY
  docker cp "${WORKFLOW_SRC}" \
    "${WEB_CID}:/var/www/html/sts/backups/session_editor/start_session.workflow.json"
  echo "==> Updated start_session.workflow.json and hart_seed_config.json warm_start defaults" | tee -a "${LOG}"
fi

echo "==> Done. Full log: ${LOG}" | tee -a "${LOG}"
