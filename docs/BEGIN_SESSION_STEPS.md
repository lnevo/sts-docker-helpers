# Begin session — STS user steps

`begin_session` opens a **new operating session** from the end-of-prior-session layout (warm start or after `play_operating_session`). It is the **session-open prep** a crew chief would do before locals leave the yard.

**Script:** `begin_session.sh --run-stg-scully`  
**Session counter:** advances **exactly once** (e.g. 3 → 4).  
**Switch list snapshot:** **Immediately after begin_session completes** — before any local runs that day.

---

## Prerequisites (what the layout must look like)

You cannot begin a session until the **prior session ended correctly**:

1. **STG-SCULLY backlog at Scully** — Cars sitting at Scully / McKees Rock offline, eligible for the **STG-SCULLY** job. This is normal end-of-session state from `play_operating_session` or the last simulated session in warm start.
2. **STG-SCULLY not yet run for today** — The staging swap is the *first* job of the new session.
3. Optional: **D749 on train** with Demmler inbound block from yesterday’s bookend (typical).

If STG-SCULLY backlog exists and you skip running it, begin_session **blocks** and reports an error.

---

## High-level flow

```
End of prior session (STG-SCULLY waiting at Scully)
    → run STG-SCULLY
    → load/unload offline transitions
    → increment session number
    → fill unfilled orders
    → reposition empties
    → auto-assign locals
    → [GENERATE SWITCH LISTS HERE]
    → crew operates session (play_operating_session / manual STS)
```

---

## Step-by-step (STS user perspective)

### 1. Run STG-SCULLY

**What you do in STS:** Open the **STG-SCULLY** job, assign eligible cars at Scully, pick up, set out at Scully offline (McKees Rock), complete load/unload as needed.

**Why:** Clears yesterday’s Scully staging backlog so today’s locals start from a clean Scully interchange.

**Automated:** `begin_session.sh --run-stg-scully` (default in simulation).

---

### 2. Load / unload at offline spots

**What you do in STS:** Operations → load/unload (or let instant transitions complete) for cars at offline industries that are ready.

**Why:** Cars swapped by STG-SCULLY may need status transitions before dispatch.

---

### 3. Increment session number

**What you do in STS:** Settings → advance **session number** by 1.

**Why:** Marks the start of a new operating session for history, order generation, and switch list headers.

**Important:** This is the **only** session increment for this cycle. Playing the session afterward does **not** increment again.

---

### 4. Fill unfilled car orders

**What you do in STS:** Orders → fill orders — match available cars to open waybills where rules allow.

**Why:** Gets revenue traffic onto cars before job assignment.

**Note:** If no eligible cars exist, orders stay unfilled (common when the fleet is saturated).

---

### 5. Reposition empty cars

**What you do in STS:** Create reposition (“E”) orders for empties away from home and fill a fraction of them.

**Why:** Moves surplus empties toward where orders will need them.

---

### 6. Auto-assign cars to jobs

**What you do in STS:** Auto-assign (or manually assign) eligible cars to **D749**, **NVL**, **CK1**, and other locals. Staging jobs (**STG-SCULLY**, **STG-DEMMLER**) are skipped.

**Why:** Builds the **opening consists** each crew sees on their switch list — who is on train at session open.

---

### 7. Review session-open state

**What you check in STS:**

| Area | What to look for |
|------|------------------|
| **Orders** | Unfilled count; newly filled waybills |
| **D749** | Cars assigned / on train (Demmler → South work may follow in play) |
| **NVL** | Scully pickups assigned after STG-SCULLY cleared |
| **CK1** | Reload/outbound coke at South if any |
| **STG-SCULLY** | Backlog should be **zero** (job complete) |

The begin_session report prints unfilled waybills, empties off-home, D749 on train, and per-job assign eligibility.

---

## Switch list capture point

**Correct moment:** Right after steps 1–6, **before** any of the following:

- D749 South setout / Demmler pickup (session-start moves)
- NVL Scully → South run
- CK1 Shenango / weigh cycle
- Session-end bookend (STG-DEMMLER, NVL → Scully)

That snapshot is **“session open — crews leave the yard.”**

**Command:**

```bash
./bin/begin_session.sh --run-stg-scully --switchlists
```

`--switchlists` runs `generate_switchlists.sh` immediately after prep.

---

## What begin_session does *not* do

- Does **not** run a full operating session (no CK1 weigh, no NVL island work, no session-end bookend).
- Does **not** generate new revenue orders unless `--generate` is passed.
- Does **not** run **STG-DEMMLER** (that is session-end bookend during play).
- Does **not** leave STG-SCULLY backlog for tomorrow — it **clears** today’s backlog at open.

---

## Typical begin_session report (reading the output)

```
Session: 3 → 4
STG-SCULLY: assigned=… pickup=… setout=…
Load/unload transitions: …
Orders filled: …
Reposition orders created: …
Cars assigned to jobs: …

--- Orders (not filled) ---
Unfilled waybills: …

--- Yard / train ---
D749 on train: … (set out at South Yard to open the session)
Awaiting job assignment: …
STG-SCULLY eligible at Scully: 0
```

Footer guidance:

- **“All eligible orders filled…”** — Ready for switch lists and play.
- **“D749 South setout, then local jobs”** — Next manual/simulated step after lists.
- **Blocked** — STG-SCULLY still pending; fix before continuing.

---

## Optional flags (simulation / troubleshooting)

| Flag | Effect |
|------|--------|
| `--run-stg-scully` | Run STG-SCULLY automatically (required if backlog exists) |
| `--no-fill` | Skip order fill |
| `--no-assign` | Skip auto-assign |
| `--no-increment` | Keep session number (used only inside switch list dry-run) |
| `--generate` | Generate new revenue orders for the new session |
| `--switchlists` | Generate phased HTML lists after prep |

---

## Related commands

```bash
# Open session + lists (typical)
./bin/begin_session.sh --run-stg-scully --switchlists

# Prep only
./bin/begin_session.sh --run-stg-scully

# Lists only (DB already at session open)
./bin/generate_switchlists.sh --format=phased
```

See also: **`WARM_START_STEPS.md`**, **`FULL_OPERATING_SESSION.md`**.
