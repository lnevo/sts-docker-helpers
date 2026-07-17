#!/usr/bin/env bash
# Rewind hart_session10_locked → run sessions 11..20 under mandatory train order.
# Sweep flow levers across 3 static generate seeds; score only s11-20.
set -euo pipefail
_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

STAMP="$(date +%Y%m%d_%H%M%S)"
BASE_WF="${BACKUPS_DIR}/session_editor/hart_flow_fill_gap_best.workflow.json"
TMP_WF="${BACKUPS_DIR}/session_editor/_s10_flow_case.workflow.json"
CASE_WF="${BACKUPS_DIR}/session_editor/hart_flow_s10_case.workflow.json"
LOCK="${BACKUPS_DIR}/hart_session10_locked"
LOG="${BACKUPS_DIR}/session_editor/traffic_s10_flow_sweep_${STAMP}.log"
SCORES="${BACKUPS_DIR}/session_editor/traffic_s10_flow_scores_${STAMP}.tsv"
SEEDS=(11 22 33)

WEB_CID="$("${COMPOSE[@]}" ps -q web)"
DB_CID="$("${COMPOSE[@]}" ps -q db)"
[[ -n "$WEB_CID" && -n "$DB_CID" ]] || { echo "web/db containers not running"; exit 1; }

# Freeze rewind point once.
if [[ ! -f "$LOCK" ]]; then
  cp -f "${BACKUPS_DIR}/hart_session10" "$LOCK"
fi

docker cp "${DIAGNOSTICS_DIR}/traffic_from_session2.php" "${WEB_CID}:/var/www/html/sts/traffic_from_session2.php"
docker cp "${STS_DOCKER}/sts/session_helpers.php" "${WEB_CID}:/var/www/html/sts/session_helpers.php"
docker cp "${STS_DOCKER}/sts/operations_stats.php" "${WEB_CID}:/var/www/html/sts/operations_stats.php"
docker cp "${STS_DOCKER}/sts/operational_steps_catalog.php" "${WEB_CID}:/var/www/html/sts/operational_steps_catalog.php"

restore_s10() {
  "${BIN_DIR}/apply_hart_seed.sh" --sql-file "${LOCK}" >/tmp/s10_restore.log 2>&1
  local sql="${MIGRATIONS_DIR}/tune_fleet_scarce_lanes.sql"
  [[ ! -f "$sql" ]] || docker exec -i "$DB_CID" mariadb -usts -psts sts_db3 <"$sql" >/dev/null 2>&1 || true
}

patch_case() {
  local id="$1" seed="$2" max_new="$3" gate="$4" repo="$5" coke_gate="$6" coke_lo="$7" coke_hi="$8" fill_pct="$9" mode="${10}"
  python3 - "$BASE_WF" "$TMP_WF" "$id" "$seed" "$max_new" "$gate" "$repo" "$coke_gate" "$coke_lo" "$coke_hi" "$fill_pct" "$mode" <<'PY'
import json, sys, copy
src, dst, cid, seed, max_new, gate, repo, coke_gate, coke_lo, coke_hi, fill_pct, mode = sys.argv[1:]
data = json.loads(open(src).read())
steps = data["steps"]
seed, max_new, gate, repo, coke_gate = seed, max_new, gate, repo, coke_gate
fill_pct = fill_pct

def is_coke_gen(s):
    return s.get("function") == "generate_orders" and "COKE" in str(s.get("params", {}).get("shipment", ""))

def is_auto_gen(s):
    return s.get("function") == "generate_orders" and not str(s.get("params", {}).get("shipment", "")).strip()

def is_coke_if(s):
    p = s.get("params") or {}
    return s.get("function") == "if_then" and p.get("variable") == "unfilled_orders" and str(p.get("commodity", "")).upper() == "COKE"

out = []
i = 0
while i < len(steps):
    s = copy.deepcopy(steps[i])
    fn = s.get("function")
    p = s.setdefault("params", {})
    if is_coke_if(s):
        p["value"] = str(coke_gate)
        if mode == "NO_COKE_GATE":
            i += 1
            continue  # drop gate
    if is_coke_gen(s):
        p["seed"] = str(seed)
    if is_auto_gen(s):
        p["seed"] = str(seed)
        p["max_new"] = str(max_new)
        p["max_unfilled"] = "" if gate == "NONE" else str(gate)
    if fn == "fill_orders" and mode != "SKIP_FILL_PATCH":
        p["percent"] = str(fill_pct)
    if fn == "reposition_empties":
        if mode == "REPO_AFTER_IF_FILL":
            # leave repo as-is; conditional wrapper added below
            p["percent"] = str(repo)
        elif mode == "NO_REPO":
            i += 1
            continue
        else:
            p["percent"] = str(repo)
    out.append(s)
    i += 1

# Insert conditional reposition: if filled_this_run >= 6 skip heavy repo (use light via replacing percent on skip path is hard);
# Instead: if filled_this_run >= 6 → jump past reposition (skip repo when fill already moving cars).
if mode in ("SKIP_REPO_IF_FILLED", "HEAVY_REPO_IF_COKE_UNF"):
    new_out = []
    for s in out:
        if s.get("function") == "reposition_empties":
            if mode == "SKIP_REPO_IF_FILLED":
                new_out.append({
                    "function": "if_then",
                    "params": {
                        "variable": "filled_this_run",
                        "operator": ">=",
                        "value": "6",
                        "section": "",
                        "section_label": "After Reposition",
                        "step": "",
                        "commodity": "",
                        "shipment": "",
                        "car_code": "",
                    },
                    "description": "Skip reposition when fill already moved >=6 cars.",
                })
                new_out.append(s)
                new_out.append({
                    "function": "section_label",
                    "params": {"label": "After Reposition"},
                    "description": "Resume after optional reposition.",
                })
            else:  # HEAVY_REPO_IF_COKE_UNF: default light; bump via two repos is messy — set percent high only when coke unfilled
                new_out.append({
                    "function": "if_then",
                    "params": {
                        "variable": "unfilled_orders",
                        "operator": ">=",
                        "value": "4",
                        "section": "",
                        "section_label": "Heavy Repo",
                        "step": "",
                        "commodity": "COKE",
                        "shipment": "",
                        "car_code": "",
                    },
                    "description": "If COKE unfilled < 4, use light repo only.",
                })
                light = copy.deepcopy(s)
                light["params"]["percent"] = "10"
                new_out.append(light)
                new_out.append({
                    "function": "if_then",
                    "params": {
                        "variable": "session_nbr",
                        "operator": ">=",
                        "value": "0",
                        "section": "",
                        "section_label": "After Reposition",
                        "step": "",
                        "commodity": "",
                        "shipment": "",
                        "car_code": "",
                    },
                    "description": "Skip heavy repo after light path.",
                })
                new_out.append({
                    "function": "section_label",
                    "params": {"label": "Heavy Repo"},
                })
                heavy = copy.deepcopy(s)
                heavy["params"]["percent"] = "40"
                new_out.append(heavy)
                new_out.append({
                    "function": "section_label",
                    "params": {"label": "After Reposition"},
                })
        else:
            new_out.append(s)
    out = new_out

# Dual fill: fill → repo → fill again (insert second fill after reposition / After Reposition)
if mode == "DUAL_FILL":
    new_out = []
    for s in out:
        new_out.append(s)
        label = (s.get("params") or {}).get("label", "")
        if s.get("function") == "reposition_empties" or label == "After Reposition":
            # only once after the repo step itself
            if s.get("function") == "reposition_empties":
                new_out.append({
                    "function": "fill_orders",
                    "params": {
                        "percent": "100",
                        "order_filters": {
                            "loading_location": "",
                            "unloading_location": "",
                            "consignment": "",
                            "car_code": "",
                        },
                        "car_filters": {
                            "categories": "pool,station,priority,system",
                            "current_station": "",
                            "current_location": "",
                            "car_code": "",
                        },
                    },
                    "description": "Second fill after reposition to catch newly available empties.",
                })
    out = new_out

data["steps"] = out
data["name"] = f"hart_flow_s10_{cid}"
data["description"] = f"s10 sweep {cid} seed={seed} new={max_new} gate={gate} repo={repo} coke_gate={coke_gate} coke={coke_lo}-{coke_hi} fill={fill_pct} mode={mode}"
assert len(out) > 50, len(out)
open(dst, "w").write(json.dumps(data, indent=4) + "\n")
print(f"patched {cid}: steps={len(out)} seed={seed} new={max_new} gate={gate} repo={repo} cg={coke_gate} coke={coke_lo}-{coke_hi} fill={fill_pct} mode={mode}")
PY
  cp -f "$TMP_WF" "$CASE_WF"
  # coke volume on shipments
  docker exec -u www-data "$WEB_CID" php -r "
  chdir('/var/www/html/sts'); require 'open_db.php'; \$d=open_db();
  mysqli_query(\$d, 'UPDATE shipments SET min_amount=${coke_lo}, max_amount=${coke_hi} WHERE code IN (\"COKE-USS-BULK\",\"COKE-CLEV-BULK\")');
  " >/dev/null
}

echo -e "id\tseed\tscore\tcoke\tcoke_var\tmr\tmp\tmr_mp_bal\tnvlo\tnvlr\tnvl_ni\tnvl_shen\tnvl_kinds\td749s\td749o\tfill\tunf\ttrain\tholdup" >"$SCORES"
echo "S10 flow sweep → score s11-20 | seeds=${SEEDS[*]} | lock=$LOCK" | tee "$LOG"

# id max_new gate repo coke_gate coke_lo coke_hi fill mode
CASES=(
  "BASE|8|40|25|8|2|4|100|BASE"
  "REPO0|8|40|0|8|2|4|100|NO_REPO"
  "REPO10|8|40|10|8|2|4|100|BASE"
  "REPO40|8|40|40|8|2|4|100|BASE"
  "MAX6|6|40|25|8|2|4|100|BASE"
  "MAX10|10|40|25|8|2|4|100|BASE"
  "MAX12|12|40|25|8|2|4|100|BASE"
  "GATE35|8|35|25|8|2|4|100|BASE"
  "GATE50|8|50|25|8|2|4|100|BASE"
  "CG6|8|40|25|6|2|4|100|BASE"
  "CG10|8|40|25|10|2|4|100|BASE"
  "CG12|8|40|25|12|2|4|100|BASE"
  "COKE12|8|40|25|8|1|2|100|BASE"
  "COKE23|8|40|25|8|2|3|100|BASE"
  "COKE35|8|40|25|8|3|5|100|BASE"
  "FILL80|8|40|25|8|2|4|80|BASE"
  "SKIPREPO_FILL|8|40|25|8|2|4|100|SKIP_REPO_IF_FILLED"
  "REPO_BY_COKE|8|40|25|8|2|4|100|HEAVY_REPO_IF_COKE_UNF"
  "DUAL_FILL|8|40|25|8|2|4|100|DUAL_FILL"
  "MAX10_CG10|10|40|25|10|2|4|100|BASE"
  "MAX6_COKE12|6|40|25|8|1|2|100|BASE"
  "REPO10_CG10|8|40|10|10|2|3|100|BASE"
)

for case in "${CASES[@]}"; do
  IFS='|' read -r id max_new gate repo coke_gate coke_lo coke_hi fill mode <<<"$case"
  for seed in "${SEEDS[@]}"; do
    echo "==> ${id} seed=${seed}" | tee -a "$LOG"
    restore_s10
    patch_case "$id" "$seed" "$max_new" "$gate" "$repo" "$coke_gate" "$coke_lo" "$coke_hi" "$fill" "$mode" | tee -a "$LOG"
    out="$(docker exec -u www-data \
      -e "STS_TRAFFIC_SEED=${seed}" \
      -e STS_SCORE_FROM=11 \
      "$WEB_CID" \
      php /var/www/html/sts/traffic_from_session2.php 20 hart_flow_s10_case 2>>"$LOG")"
    json="$(printf '%s\n' "$out" | rg '^TRAFFIC_JSON=' | cut -d= -f2- || true)"
    if [[ -z "$json" ]]; then
      echo "${id}|seed=${seed}|FAIL" | tee -a "$LOG"
      echo -e "${id}\t${seed}\tFAIL\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t" >>"$SCORES"
      continue
    fi
    python3 - "$id" "$seed" "$json" >>"$SCORES" <<'PY'
import json,sys,math
cid,seed,d=sys.argv[1],sys.argv[2],json.loads(sys.argv[3])
rows=[r for r in d['rows'] if int(r.get('s',0))>=11]
n=max(1,len(rows))
avg=lambda k: sum(float(r.get(k,0) or 0) for r in rows)/n
cokes=[float(r.get('coke',0) or 0) for r in rows]
coke_avg=sum(cokes)/n
coke_var=sum((x-coke_avg)**2 for x in cokes)/n
mr=sum(int(r.get('ck_mr',0) or 0) for r in rows)
mp=sum(int(r.get('ck_mp',0) or 0) for r in rows)
tot=max(1,mr+mp)
bal=1.0-abs(mr-mp)/tot
# NVL destination variety: how many of NI/Shen/South/Dem/MP/MR appear on average
keys=['nvl_ni','nvl_shen','nvl_south','nvl_dem','nvl_mp','nvl_mr']
kinds=sum(1 for k in keys if avg(k)>0.15)
train=avg('ck1')+avg('d749s')+avg('d749o')+avg('nvlo')+avg('nvlr')
print(f"{cid}\t{seed}\t{d['score']:.1f}\t{coke_avg:.2f}\t{coke_var:.2f}\t{mr}\t{mp}\t{bal:.3f}\t{avg('nvlo'):.2f}\t{avg('nvlr'):.2f}\t{avg('nvl_ni'):.2f}\t{avg('nvl_shen'):.2f}\t{kinds}\t{avg('d749s'):.2f}\t{avg('d749o'):.2f}\t{avg('fill'):.2f}\t{avg('unfilled'):.2f}\t{train:.2f}\t{d.get('holdup','')}")
PY
    # also human line
    tail -1 "$SCORES" | tee -a "$LOG"
  done
done

echo | tee -a "$LOG"
echo "=== RANK by mean score across seeds (flow-aware) ===" | tee -a "$LOG"
python3 - "$SCORES" <<'PY' | tee -a "$LOG"
import csv,sys,statistics as st
from collections import defaultdict
path=sys.argv[1]
rows=list(csv.DictReader(open(path), delimiter='\t'))
by=defaultdict(list)
for r in rows:
    if r.get('score') in (None,'','FAIL'): continue
    by[r['id']].append(r)

def f(x):
    try: return float(x)
    except: return 0.0

ranked=[]
for cid, rs in by.items():
    scores=[f(r['score']) for r in rs]
    cokes=[f(r['coke']) for r in rs]
    vars_=[f(r['coke_var']) for r in rs]
    bals=[f(r['mr_mp_bal']) for r in rs]
    nvlo=[f(r['nvlo']) for r in rs]
    nvlr=[f(r['nvlr']) for r in rs]
    kinds=[f(r['nvl_kinds']) for r in rs]
    trains=[f(r['train']) for r in rs]
    unfs=[f(r['unf']) for r in rs]
    # Composite: score + coke steadiness + MR/MP balance + NVL activity/variety
    # Prefer low coke_var, high bal, high nvl, high kinds
    comp = (
        st.mean(scores)
        + max(0, 8 - st.mean(vars_)) * 0.8
        + st.mean(bals) * 8
        + min(10, st.mean(nvlo) + st.mean(nvlr)) * 0.4
        + st.mean(kinds) * 1.2
        - max(0, st.mean(unfs) - 35) * 0.15
    )
    ranked.append((comp, st.mean(scores), st.pstdev(scores) if len(scores)>1 else 0.0,
                   st.mean(cokes), st.mean(vars_), st.mean(bals),
                   st.mean(nvlo), st.mean(nvlr), st.mean(kinds), st.mean(trains), st.mean(unfs), cid, len(rs)))

ranked.sort(reverse=True)
print(f"{'rank':<5}{'id':<16}{'comp':>7}{'score':>7}{'±':>5}{'coke':>6}{'cVar':>6}{'bal':>6}{'NVLO':>6}{'NVLR':>6}{'kinds':>6}{'train':>7}{'unf':>6} n")
for i,(comp,sc,sd,coke,cv,bal,nvlo,nvlr,kinds,train,unf,cid,n) in enumerate(ranked,1):
    print(f"{i:<5}{cid:<16}{comp:7.1f}{sc:7.1f}{sd:5.1f}{coke:6.2f}{cv:6.2f}{bal:6.3f}{nvlo:6.2f}{nvlr:6.2f}{kinds:6.1f}{train:7.1f}{unf:6.1f} {n}")
print("\nTop 5 detail by seed:")
for _,sc,sd,coke,cv,bal,nvlo,nvlr,kinds,train,unf,cid,n in ranked[:5]:
    print(f"\n{cid}:")
    for r in by[cid]:
        print(f"  seed={r['seed']}: score={r['score']} coke={r['coke']} var={r['coke_var']} MR/MP={r['mr']}/{r['mp']} bal={r['mr_mp_bal']} "
              f"NVL={r['nvlo']}/{r['nvlr']} NI={r['nvl_ni']} Shen={r['nvl_shen']} kinds={r['nvl_kinds']} train={r['train']} unf={r['unf']}")
PY

echo "LOG=$LOG"
echo "SCORES=$SCORES"
