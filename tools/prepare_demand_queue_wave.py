#!/usr/bin/env python3
"""Build queue/reposition test recipes from the current canonical workflow."""

from __future__ import annotations

import copy
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EDITOR = ROOT / "sts-backups" / "session_editor"
BASE = EDITOR / "hart_session.workflow.json"

CASES = {
    "wave1_BASE_M6_G40_R25.workflow.json": (6, 40, False),
    "wave1_Q20_M10_R25.workflow.json": (10, 20, False),
    "wave1_Q25_M10_R25.workflow.json": (10, 25, False),
    "wave1_BASE_M6_G40_DYNAMIC.workflow.json": (6, 40, True),
    "wave1_Q20_M10_DYNAMIC.workflow.json": (10, 20, True),
    "wave1_Q25_M10_DYNAMIC.workflow.json": (10, 25, True),
}


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
    }


def goto(label: str) -> dict:
    return {
        "function": "goto",
        "params": {"section": "", "section_label": label, "step": ""},
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
            "section": "",
            "section_label": label,
            "step": "",
        },
    }


def dynamic_reposition_block() -> list[dict]:
    # Low fill means empties are poorly positioned: send more home.
    return [
        if_filled_at_most(3, "Heavy Reposition"),
        if_filled_at_most(7, "Medium Reposition"),
        reposition(10),
        goto("After Demand Reposition"),
        section("Medium Reposition"),
        reposition(25),
        goto("After Demand Reposition"),
        section("Heavy Reposition"),
        reposition(50),
        section("After Demand Reposition"),
    ]


def normalize_gotos(steps: list[dict]) -> None:
    sections: dict[str, tuple[int, str]] = {}
    for number, step in enumerate(steps, 1):
        if step.get("function") != "section_label":
            continue
        label = str((step.get("params") or {}).get("label") or "").strip()
        if label:
            sections[label] = (number, f"step-{number}")

    for step in steps:
        if step.get("function") not in ("if_then", "goto"):
            continue
        params = step.setdefault("params", {})
        label = str(params.get("section_label") or "").strip()
        if label in sections:
            number, section_id = sections[label]
            params["section"] = section_id
            params["step"] = str(number)


def validate(steps: list[dict], dynamic: bool) -> None:
    labels = {
        (step.get("params") or {}).get("label"): number
        for number, step in enumerate(steps, 1)
        if step.get("function") == "section_label"
    }
    required_order = [
        "D749 Outbound",
        "CK1",
        "NVL Outbound",
        "NVL Return",
        "CK1 Scale",
    ]
    positions = [labels[label] for label in required_order]
    assert positions == sorted(positions), (required_order, positions)
    assert "CK1 South Setout" not in labels
    assert "Setup Session" not in labels
    assert not any(step.get("function") == "cancel_orders" for step in steps)

    dynamic_conditions = [
        step
        for step in steps
        if step.get("function") == "if_then"
        and (step.get("params") or {}).get("variable") == "filled_this_run"
    ]
    assert len(dynamic_conditions) == (2 if dynamic else 0)


def build(base: dict, max_new: int, gate: int, dynamic: bool) -> dict:
    recipe = copy.deepcopy(base)
    output: list[dict] = []
    generic_generators = 0
    reposition_steps = 0

    for step in recipe["steps"]:
        params = step.get("params") or {}
        if step.get("function") == "generate_orders" and not str(
            params.get("shipment") or ""
        ).strip():
            generic_generators += 1
            params["max_new"] = str(max_new)
            params["max_unfilled"] = str(gate)

        if step.get("function") == "reposition_empties":
            reposition_steps += 1
            if dynamic:
                output.extend(dynamic_reposition_block())
                continue
            params["percent"] = "25"

        output.append(step)

    assert generic_generators == 1
    assert reposition_steps == 1
    recipe["steps"] = output
    recipe["description"] = (
        f"Wave 1: max_new={max_new}, queue gate={gate}, "
        f"reposition={'10/25/50 by filled_this_run' if dynamic else 'static 25%'}. "
        "Mandatory D749 -> CK1 -> NVL -> CK1 Scale; no cancellation."
    )
    normalize_gotos(output)
    validate(output, dynamic)
    return recipe


def main() -> None:
    base = json.loads(BASE.read_text())
    n = len(base.get("steps", []))
    assert n == 72, f"Canonical workflow must be 72 steps (got {n})"

    for filename, (max_new, gate, dynamic) in CASES.items():
        recipe = build(base, max_new, gate, dynamic)
        path = EDITOR / filename
        path.write_text(json.dumps(recipe, indent=4, ensure_ascii=True) + "\n")
        print(f"{filename}: {len(recipe['steps'])} steps")


if __name__ == "__main__":
    main()
