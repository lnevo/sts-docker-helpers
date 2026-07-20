#!/usr/bin/env python3
"""Build empty-management / gate lever recipes from current hart_session."""

from __future__ import annotations

import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EDITOR = ROOT / "sts-backups" / "session_editor"
BASE = EDITOR / "hart_session.workflow.json"

# name -> (max_new, gate, repo_pct|'dynamic', fill_pct, mr_gate, mp_gate)
# mr_gate / mp_gate = unfilled final-dest thresholds for CLEV / USS bulk skips
CASES: dict[str, tuple] = {
    # Baseline
    "eg_BASE_M6_G40_R25": (6, 40, 25, 100, 4, 4),
    # Empty management
    "eg_REPO10_M6_G40": (6, 40, 10, 100, 4, 4),
    "eg_REPO40_M6_G40": (6, 40, 40, 100, 4, 4),
    "eg_REPO50_M6_G40": (6, 40, 50, 100, 4, 4),
    "eg_DYNAMIC_M6_G40": (6, 40, "dynamic", 100, 4, 4),
    "eg_FILL75_R40": (6, 40, 40, 75, 4, 4),
    # General gates
    "eg_M8_G35_R25": (8, 35, 25, 100, 4, 4),
    "eg_M4_G50_R25": (4, 50, 25, 100, 4, 4),
    "eg_M6_G30_R40": (6, 30, 40, 100, 4, 4),
    # Coke lane gates (press MR/MP consistency)
    "eg_COKE_MR3_MP5_R25": (6, 40, 25, 100, 3, 5),
    "eg_COKE_MR5_MP3_R40": (6, 40, 40, 100, 5, 3),
    "eg_COKE_MR6_MP4_R25": (6, 40, 25, 100, 6, 4),
}


def refresh_gotos(steps: list[dict]) -> None:
    labels: dict[str, int] = {}
    for i, step in enumerate(steps, 1):
        if step.get("function") == "section_label":
            lab = ((step.get("params") or {}).get("label") or "").strip()
            if lab:
                labels[lab] = i
    for step in steps:
        if step.get("function") not in ("if_then", "goto"):
            continue
        params = step.setdefault("params", {})
        lab = (params.get("section_label") or "").strip()
        if lab and lab in labels:
            params["step"] = str(labels[lab])
            params["section"] = f"step-{labels[lab]}"
    for step in steps:
        if step.get("function") == "if_then" and (step.get("params") or {}).get("variable") == "session_nbr":
            inc = next(
                i for i, x in enumerate(steps, 1) if x.get("function") == "increment_session"
            )
            params = step["params"]
            params["section_label"] = ""
            params["step"] = str(inc)
            params["section"] = f"step-{inc}"


def section(label: str) -> dict:
    return {
        "function": "section_label",
        "params": {"label": label},
        "catalog_description": "Section heading with optional remarks (non-operational).",
    }


def reposition(percent: int) -> dict:
    return {
        "function": "reposition_empties",
        "params": {
            "mode": "reposition_to_home",
            "percent": str(percent),
            "filters": {
                "car_code": "",
                "current_station": "",
                "current_location": "",
                "home_station": "",
                "home_location": "",
                "off_home_only": "",
            },
        },
        "catalog_description": "Reposition empty cars: send off-home cars home, or update with a chosen destination.",
    }


def if_filled_at_most(value: int, label: str) -> dict:
    return {
        "function": "if_then",
        "params": {
            "variable": "filled_this_run",
            "operator": "<=",
            "value": str(value),
            "commodity": "",
            "shipment": "",
            "car_code": "",
            "loading_location": "",
            "unloading_location": "",
            "final_destination": "",
            "section": "",
            "section_label": label,
            "step": "",
        },
        "catalog_description": "When true, skip forward to a later section.",
    }


def goto(label: str) -> dict:
    return {
        "function": "goto",
        "params": {"section": "", "section_label": label, "step": ""},
        "catalog_description": "Skip forward to a later section.",
    }


def dynamic_reposition_block() -> list[dict]:
    return [
        if_filled_at_most(3, "Heavy Reposition"),
        if_filled_at_most(7, "Medium Reposition"),
        reposition(10),
        goto("After Reposition"),
        section("Medium Reposition"),
        reposition(25),
        goto("After Reposition"),
        section("Heavy Reposition"),
        reposition(50),
        section("After Reposition"),
    ]


def patch_case(
    steps: list[dict],
    max_new: int,
    gate: int,
    repo,
    fill_pct: int,
    mr_gate: int,
    mp_gate: int,
) -> list[dict]:
    out = copy.deepcopy(steps)
    for step in out:
        fn = step.get("function")
        params = step.setdefault("params", {})
        if fn == "generate_orders":
            ship = (params.get("shipment") or "").strip()
            if ship == "":
                params["max_new"] = str(max_new)
                params["max_unfilled"] = str(gate)
        if fn == "fill_orders":
            params["percent"] = str(fill_pct)
        if fn == "reposition_empties" and repo != "dynamic":
            params["percent"] = str(repo)
        if fn == "if_then" and params.get("variable") == "unfilled_orders":
            dest = (params.get("final_destination") or "").strip()
            if "McKees Rocks" in dest:
                params["value"] = str(mr_gate)
            elif "Mckeesport" in dest or "ckeesport" in dest:
                params["value"] = str(mp_gate)

    if repo == "dynamic":
        # Replace the single reposition_empties with dynamic block.
        rebuilt: list[dict] = []
        for step in out:
            if step.get("function") == "reposition_empties":
                rebuilt.extend(dynamic_reposition_block())
            else:
                rebuilt.append(step)
        out = rebuilt

    refresh_gotos(out)
    return out


def main() -> None:
    base = json.loads(BASE.read_text())
    base_steps = base["steps"]
    for name, (max_new, gate, repo, fill_pct, mr_gate, mp_gate) in CASES.items():
        recipe = copy.deepcopy(base)
        recipe["name"] = name
        recipe["source_workflow"] = "hart_session.workflow.json"
        recipe["description"] = (
            f"Empty/gate lever: max_new={max_new} gate={gate} repo={repo} "
            f"fill={fill_pct} MR>={mr_gate} MP>={mp_gate}"
        )
        recipe["steps"] = patch_case(base_steps, max_new, gate, repo, fill_pct, mr_gate, mp_gate)
        path = EDITOR / f"{name}.workflow.json"
        path.write_text(json.dumps(recipe, indent=4) + "\n")
        print(f"wrote {path.name} steps={len(recipe['steps'])}")


if __name__ == "__main__":
    main()
