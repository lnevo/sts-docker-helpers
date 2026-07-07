# HART STS layout requirements log

Living notes for seed data, job steps, shipments, and track-scale behavior. Update this file when layout rules change so future edits stay consistent.

**STS UI fixes to port:** see [`sts-docker/UI_IMPROVEMENTS_PORTING.md`](sts-docker/UI_IMPROVEMENTS_PORTING.md) (e.g. auto-assign dropdown counts for Build Switch Lists).

---

## Job steps

### Step numbering

- All job `step_number` values use **increments of 10** (10, 20, 30, …).
- When inserting a new step, renumber later steps and update matching `pu_criteria.step_nbr` rows.

### One destination per pickup step (interchange yards)

**Rule:** At Demmler or Scully (and satellite yards picking for those blocks), **each destination gets its own job step** — never combine Demmler and Scully pickups on one step.

**Why:** STS auto-assign matches `pu_criteria` by `step_nbr` + `dest_station_id`. Discrete steps match operator workflow and mirror existing locals:

| Job | Pattern |
|-----|---------|
| **D749** @ Demmler | Step 10 → Scully; step 20 → Island; step 30 → Demmler; step 40 @ South Yard → Demmler outbound |
| **NVL** @ Scully | Step 10 → Island; step 20 → Demmler; step 30 → Scully; island work step 50 |
| **CK1** @ North Yard | Step 20 → Scully Offline (15); step 50 → Demmler Offline (14); **only job with Shenango** (step 80 setout) |

**CK1 sequence (current):**

| Step | Station | Pickup | Set out | Purpose |
|------|---------|--------|---------|---------|
| 10 | North Yard (11) | ✓ | ✓ | North Yard coke staging |
| 20 | North Yard (11) | ✓ | | Scully Offline export — `dest_station_id` = 15 |
| 50 | North Yard (11) | ✓ | | Demmler Offline export — `dest_station_id` = 14 |
| 70 | Shenango (12) | ✓ | | Scully Offline export — `dest_station_id` = 15 |
| 100 | Shenango (12) | ✓ | | Demmler Offline export — `dest_station_id` = 14 |
| 80 | Shenango (12) | ✓ | ✓ | Set out coke loads at Shenango (CK1 only) |
| 110 | South Yard (8) | ✓ | | North Yard — `dest_station_id` = 11 |
| 130 | South Yard (8) | ✓ | | Shenango — `dest_station_id` = 12 |
| 150 | South Yard (8) | | ✓ | Weighing/classification |

All jobs use **dest-only** `pu_criteria` (blank `car_status`). CK1 is the only job with a Shenango step. Demmler Offline = 14, Scully Offline = 15.

### Pickup criteria (`pu_criteria`)

- One row per `(job_id, step_nbr, dest_station_id)` combination for pickup steps.
- `dest_station_id` is a **routing station** (not a location code). STS auto-assign expands it to all location IDs at that station.
- Station IDs: Neville Island = 3, South Yard = 8, Scully = 9, Demmler = 10, North Yard = 11, Shenango Coke Works = 12, Demmler Offline = 14, Scully Offline = 15, West Yard = 2, East Yard = 13.
- **All jobs:** `car_status` is **blank** — auto-assign matches **dest_station_id** only.
- Satellite-yard staging steps (North/West general) may list **multiple** `dest_station_id` values on the **same** step when destinations are island industries or South Yard — not Demmler/Scully interchange blocks.

**Optional `car_status` filters (not enabled in seed today):**

| Car status | `dest_station_id` means |
|------------|-------------------------|
| **Ordered** (load order) | Match cars whose shipment **loads** at a location on that station |
| **Loaded** | Match cars whose shipment **unloads** at a location on that station |

Example if enabled later: D749 step 35 @ Demmler → Shenango with **Ordered**; step 40 @ Shenango → Demmler export with **Loaded**; STG3 coke export steps with **Loaded**; North Yard Shenango reload with **Ordered**.

---

## Coke shipments and locations

### Interchange yards (SCL / DEM)

| Code | Station | Role |
|------|---------|------|
| `SCL` | Scully (9) | Home yard — empty returns, inbound pickup, outbound setout (pink) |
| `SCL-OUT-CLEV` | Scully (9) | Offline unload — POHC / NS coke lane |
| `DEM` | Demmler (10) | Home yard — empty returns, inbound pickup, outbound setout (purple) |
| `DEM-OUT-USS` | Demmler (10) | Offline unload — Edgar Thomson / URR coke lane |

Home yards **`SCL`** (pink) and **`DEM`** (purple) handle all yard-level car handling. No separate inbound/outbound yard block locations. Island locals and IX through traffic use Offline party locations with `-IN-` / `-OUT-` prefixes (`SCL-IN-{party}`, `SCL-OUT-{party}`, `DEM-IN-{party}`, `DEM-OUT-{party}`).

### IX through traffic (Phase 3)

Through POHC↔CSX moves use the same Offline party pattern as island locals, but **never** touch `NIL-*` spots. Full mapping: [`hart_ix_shipping_map_proposed.csv`](hart_ix_shipping_map_proposed.csv). `generate_hart_seed.py` loads this map and sets IX shipment load/unload FKs from `proposed_load_loc` / `proposed_unload_loc`.

| Direction | Load (Offline) | Unload (Offline) | `dest_station_id` |
|-----------|----------------|------------------|-------------------|
| POHC→CSX | `SCL-IN-{party}` @ Scully (9) | `DEM-OUT-{party}` @ Demmler (10) | 10 |
| CSX→POHC | `DEM-IN-{party}` @ Demmler (10) | `SCL-OUT-{party}` @ Scully (9) | 9 |

- **30 shipments** (`IX-*` codes) from interchange waybill cards 43–72; mnemonic renames in [`hart_shipment_code_renames_proposed.csv`](hart_shipment_code_renames_proposed.csv).
- **~46 Offline locations** in seed (reuse of Phase 1–2 codes plus IX-only party codes on the correct side).

### Coke shipment codes

| Code | Load | Unload | Notes |
|------|------|--------|-------|
| COKE-USS | NIL-SHEN-COKE | DEM-OUT-USS | CSX \| URR — outbound (1 car) |
| COKE-CLEV | NIL-SHEN-COKE | SCL-OUT-CLEV | POHC \| NS via McKees Rocks (1 car) |
| COKE-USS-BULK | NIL-SHEN-COKE | DEM-OUT-USS | CSX \| URR (5 cars) |
| COKE-CLEV-BULK | NIL-SHEN-COKE | SCL-OUT-CLEV | POHC \| NS via McKees Rocks (5 cars) |
| COKE-RELOAD-NORTH | SOUTH-SCALE | NORTH | Off-tolerance reload |

**Demmler Offline** (routing station 14) and **Scully Offline** (routing station 15) hold CSX and POHC offline party tracks (`DEM-IN-*`, `DEM-OUT-*`, `SCL-IN-*`, `SCL-OUT-*`). Interchange yards **Demmler Yard** (10) and **Scully Yard** (9) keep home yards only (`DEM`, `SCL`). **STG-DEMMLER** / **STG-SCULLY**: step 10 pickup at yard; step 11 setout at offline (yard receive); steps 12–50 pickup+setout at offline; step 60 pickup+setout at home yard. Cross-interchange offline transfers are **not** staging: **D749** step 15 moves South Yard → Demmler Offline, step 35 moves Demmler Yard → Scully Offline; **NVL** step 35 moves Scully Yard → Demmler Offline. **NVL** also picks for Demmler Offline and Scully Offline at Neville Island (steps 75, 85) and Scully Offline at South Yard (step 95).

### Track scale reassignment after weigh

- **Inbound to scale:** cars with an active order unloading at `SOUTH-SCALE` may assign **outbound** after an in-tolerance weigh.
- **Loaded coke fleet, off tolerance:** weighable COKE-pool cars may reassign to **reload** (`allows_scale_reassign` in API); prior order closes on assign.
- **Loaded reassignment:** when the car still has coal (Loaded/Loading/Unloading), closing the prior order keeps **Loaded** status through assign — including reload orders back to North Yard.
- **In tolerance with a final unload** (order does not unload at the scale): assignment UI stays hidden; use **Reassign Order** after weigh to open outbound assignment (prior order closes on assign).
- UI prototype: **outbound** or **reload** is chosen automatically from tolerance (no manual selector).
- Operations dashboard **To Weigh** uses `track_scale_counts_toward_weigh_stat()` — includes loaded COKE-pool cars at the scale or on a South Yard train, not only cars without orders.

---

## Files to touch for layout changes

| Change type | Files |
|-------------|-------|
| Jobs / steps / criteria | [`hart_seed_config.json`](hart_seed_config.json), [`generate_hart_seed.py`](generate_hart_seed.py) |
| Regenerate seed | `python3 generate_hart_seed.py` → [`sts-backups/hart_seed`](sts-backups/hart_seed) |
| Shipment intervals | [`tune_shipment_orders.sql`](tune_shipment_orders.sql), [`balance_shipment_yards.py`](balance_shipment_yards.py) |
| Live DB patch | One-off `*_migration.sql` (see [`coke_shipment_migration.sql`](coke_shipment_migration.sql), [`ym1_job_steps_migration.sql`](ym1_job_steps_migration.sql), [`ck1_job_steps_migration.sql`](ck1_job_steps_migration.sql)) |
| Track scale | [`sts-backups/track_scale/track_scale_config.json`](sts-backups/track_scale/track_scale_config.json), `sts-docker/sts/track_scale*.php` |

---

## Changelog

| Date | Change |
|------|--------|
| 2026-07-06 | **YM1 job removed** — satellite yard switching dropped; D749/NVL/CK1 cover remaining traffic |
| 2026-07-06 | Yard balance auto-tuned from available fleet (`balance_shipment_yards.py`); unavailable cars excluded |
| 2026-07-06 | Phase 3 IX through traffic: Offline party load/unload locations and shipment FKs from `hart_ix_shipping_map_proposed.csv` |
| 2026-07-06 | Coke shipments: removed WEIGH; COKE-001/002 → COKE-USS/COKE-CLEV (1 car); added USS/CLEV-Bulk (5 cars) |
| 2026-07-06 | YM1: East Yard steps 30 (Demmler) and 40 (Scully) split — **no combined Demmler/Scully pickup step** |
| 2026-07-06 | CK1: East Yard steps 20 (Demmler) and 30 (Scully) added; South Yard setout renumbered to 40 |
| 2026-07-06 | Track scale: reassigned loaded coke cars stay Loaded through order swap (reload or outbound) |
| 2026-07-06 | Track scale: Reassign Order button for in-tolerance reroute without auto-opening assignment |
| 2026-07-06 | Track scale: reassignment after weigh expanded to loaded coke off-tolerance reload; hide assign when in-tolerance on final unload |
| 2026-07-06 | Removed COKE-003 direct shipment; track scale generates min/max car orders; bulk outbound codes on scale |
| 2026-07-06 | Removed COKE-SCALE (inbound to scale handled by track scale order generation) |
| 2026-07-06 | Industry location colors from `spurs` file on Neville Island `NIL-*` spots only (not interchange Offline codes) |
| 2026-07-06 | CK1: step 40 South Yard pickup for East Yard reload; setout renumbered to 50 |
| 2026-07-06 | CK1: step 60 setout at Shenango Coke Works |
| 2026-07-06 | D749/NVL: Shenango steps removed; YM1 East Yard (70–100); all jobs dest-only pu_criteria; CK1 only job at Shenango |
