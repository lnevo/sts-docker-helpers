# One full operating session — end-to-end

This document ties together **warm start**, **begin session**, **switch lists**, and **play session** into one operating cycle. Use it to see where each phase starts and ends, and **where switch lists must be captured**.

**Simulation script:** `run_session_simulations.sh --sessions N`  
**Typical numbering:** warm start ends at session **W**; first operating session is **W+1**; after N cycles, lists exist for sessions **W+1 … W+N**.

---

## The four phases of a campaign

| Phase | Runs | Session # | Purpose |
|-------|------|-----------|---------|
| **1. Warm start** | Once at setup | 0 → W | Build prior-session history |
| **2. Begin session** | Start of each operating day | W → W+1 (+1) | Open session, prep dispatch |
| **3. Switch lists** | Right after begin | Same as opened session | Crew paperwork at session open |
| **4. Play session** | Rest of operating day | Unchanged | Run locals, bookend, defer STG-SCULLY |

Then repeat phases **2 → 3 → 4** for each subsequent operating session.

```
┌─────────────────────────────────────────────────────────────────┐
│  WARM START (once)                                              │
│  Simulate sessions 1…W  →  end with STG-SCULLY backlog at Scully │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
        ┌───────────────────────────────────────────────┐
        │  REPEAT FOR EACH OPERATING SESSION:           │
        │                                               │
        │  begin_session (+1)  →  SWITCH LISTS  →  play │
        │       ▲                                      │ │
        │       └──────── STG-SCULLY backlog ──────────┘ │
        └───────────────────────────────────────────────┘
```

---

## Phase 1 — Warm start (once)

**User goal:** “The layout looks like we’ve already operated W sessions.”

See **`WARM_START_STEPS.md`** for detail.

**Summary:**

1. Restore `hart_seed` (session 0).
2. Automatically play W simulated sessions (each includes full locals + session-end bookend).
3. Each simulated session **ends** with STG-SCULLY **deferred** (cars at Scully, job not run).
4. Each new simulated session **starts** by running pending STG-SCULLY from the prior end.
5. Stop when STG-SCULLY backlog is ready and minimum session count is met.
6. Save backup (`sim_warm_start`).

**Session counter after warm start:** W (e.g. 3).  
**No switch lists** during this phase.

---

## Phase 2 — Begin session (each operating day)

**User goal:** “Open today’s session and prep trains.”

See **`BEGIN_SESSION_STEPS.md`** for detail.

**Summary:**

1. Run **STG-SCULLY** (clear Scully backlog from yesterday).
2. Load/unload offline transitions.
3. **Increment session** W → W+1 (only increment this cycle).
4. Fill unfilled orders.
5. Reposition empties.
6. Auto-assign D749, NVL, CK1, etc.

**Layout now = session open.** Crews can be dispatched.

---

## Phase 3 — Switch lists (capture point)

**User goal:** “Print/engineer lists for what each local does first today.”

**When:** Immediately after Phase 2, **before** Phase 4.

**What each job’s list represents:**

| Job | Phases on list | Represents |
|-----|----------------|------------|
| **D749** | 1 — Demmler → South Yard | Cars on D749 at open; optional legs 2–3 if South handoffs exist |
| **NVL** | 1 — Scully → South Yard | Pick up Scully traffic after STG-SCULLY |
| | 2 — Neville Island Industries | Island/Shenango work after South |
| | 3 — South Yard → Scully | Return Scully-bound traffic |
| **CK1** | 1 — South → Shenango | Reload/outbound coke at South at open |
| | 2 — Shenango → Scale | Loaded coke to weigh |
| | 3 — South setouts | After weigh/reload |

**Known gap:** The generator dry-runs additional moves for legs 2–3 (especially D749 and CK1) that belong to **play session**, not session open. Lists should snapshot **post begin_session DB state** only; see **`SWITCHLIST_BUILDING.md`** for technical notes.

---

## Phase 4 — Play session (rest of operating day)

**User goal:** “Run the session the way we would in STS.”

**Script:** `play_operating_session.sh`  
**Session counter:** unchanged (still W+1).

### 4a. Session-start moves

1. **Generate orders** (if unfilled count allows).
2. **D749 session start** — Pick up Demmler block, set out at **South Yard**.

### 4b. Dispatch cycle

3. Fill / reposition / assign / pickup / setout / load-unload for locals (staging excluded in phased pass).

### 4c. NVL before CK1

4. NVL Scully pickup and Demmler setouts (first leg of NVL’s day).

### 4d. CK1 coke train

5. Pick up loaded coke at **Shenango**.
6. Spot and **weigh** at **South Yard scale**; reloads and outbound assignments.
7. Set out reloads at Shenango; outbound/setouts at South.

### 4e. NVL after CK1

8. Pick up CK1 handoffs at Scully.
9. Island and Shenango setouts; criterion steps; Demmler/Scully finish.

### 4f. D749 remainder

10. South interchange setouts; Demmler offline work; island → Demmler; clear train.

### 4g. Session-end bookend

11. **STG-DEMMLER** — Demmler offline swap.
12. **D749** — Assign at Demmler, pick up (train holds Demmler block overnight).
13. **NVL** — Assign Scully, pick up, set out at **Scully** (NVL secured).
14. **STG-SCULLY deferred** — Cars left at Scully for **tomorrow’s begin_session**. Job **not** run.

**End state:** Same pattern warm start uses between simulated days — ready for next **begin_session**.

---

## One complete cycle (example: W = 3)

| Step | Action | Session # | Switch lists? |
|------|--------|-----------|---------------|
| 0 | Warm start completes | 3 | No |
| 1 | begin_session | 3 → **4** | **Yes — session 4 lists** |
| 2 | play session 4 | 4 | No |
| 3 | begin_session | 4 → **5** | **Yes — session 5 lists** |
| 4 | play session 5 | 5 | No |
| … | … | … | … |

After 10 cycles from warm start at 3: lists for sessions **4–13**, DB at session **13** (last play may leave backlog for 14).

---

## Full simulation command (from scratch)

```bash
./bin/run_session_simulations.sh --sessions 10
```

Internal order per cycle:

1. `apply_hart_seed.sh` + warm start once (Phase 1)
2. Loop ×10:
   - `begin_session.sh --run-stg-scully --switchlists` (Phases 2–3)
   - `play_operating_session.sh` (Phase 4), except after the last cycle

---

## STS user day sheet (single session)

Use this as a printable checklist for **one operating session** after warm start is done:

### Before crews arrive (chief / clerk)

- [ ] Confirm STG-SCULLY backlog at Scully from last session
- [ ] Run **begin session** (STG-SCULLY → increment → fill → assign)
- [ ] **Print / distribute switch lists** ← capture point
- [ ] Brief crews: D749 South setout first if called for on report

### During the session (crews)

- [ ] **D749** — Demmler ↔ South ↔ island per list phases
- [ ] **NVL** — Scully → South → island → Scully
- [ ] **CK1** — South ↔ Shenango ↔ scale ↔ setouts
- [ ] Fill orders and assign as new traffic appears (manual STS)

### End of session (chief / clerk)

- [ ] Run **STG-DEMMLER**
- [ ] Position **D749** on train with Demmler block
- [ ] Secure **NVL** at Scully
- [ ] **Leave STG-SCULLY for morning** — do not run tonight
- [ ] Backup database if desired

### Next morning

- [ ] Return to **begin session** — STG-SCULLY is step 1 again

---

## Switch list alignment summary

| Moment | Correct for lists? | Why |
|--------|-------------------|-----|
| After warm start | No | Session not opened; STG-SCULLY not run for today |
| After begin_session | **Yes** | Session open; consists assigned |
| After play session | No | Mid/end-of-day state; wrong for “start of session” lists |
| After session-end bookend | No | STG-SCULLY backlog = *next* session’s prerequisite |

---

## Related documents

- **`WARM_START_STEPS.md`** — Prior-session simulation only
- **`BEGIN_SESSION_STEPS.md`** — Session-open prep only
- **`SWITCHLIST_BUILDING.md`** — Generator implementation and known gaps
