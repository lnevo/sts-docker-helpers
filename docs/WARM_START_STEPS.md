# Warm start — STS user steps

Warm start simulates **prior operating sessions** so the layout looks like a railroad that has already been running. You run it **once** after restoring `hart_seed` (session 0). It does not open a new session for you to play; it builds history and leaves the layout ready for the **first** `begin_session`.

**Script:** `apply_warm_start.sh --tracked`  
**Typical end state:** session 3 (varies), cars at Scully waiting on **STG-SCULLY**, D749 on train with Demmler block, NVL secured at Scully.

---

## What you are trying to achieve

Before the first live session, the yard should look like the **end of a normal session**:

- Revenue orders exist (some filled, some not).
- Locals have run through a full day (D749, NVL, CK1).
- **STG-DEMMLER** has run (Demmler offline swap).
- **STG-SCULLY has not run** — cars are **at Scully** eligible for the staging job.
- Session number reflects how many prior sessions were simulated.

That end-of-session snapshot is what `begin_session` expects as its starting point.

---

## High-level flow

```
hart_seed (session 0)
    → simulate session 1 … session N (automatic)
    → stop when STG-SCULLY backlog is ready at Scully
    → save backup (e.g. sim_warm_start)
```

Warm start **increments the session number once per simulated session**. It does **not** run begin-session prep (fill + assign for the *next* session). That is always `begin_session`.

---

## Per simulated session (what STS would show if you played it)

Each simulated session is one full operating day. The simulator runs them back-to-back without stopping for switch lists.

### A. Session opens (start of simulated day N)

1. **Clear pending STG-SCULLY** — If cars were left at Scully from the *previous* simulated session end, run **STG-SCULLY** now (swap at Scully offline). This is the handoff from “last session ended here” to “today’s session starts.”
2. **Generate revenue orders** — New waybills for this session (skipped if too many unfilled orders already exist).
3. **D749 morning move** — Assign ordered cars at Demmler, pick up on D749, set out at **South Yard** (Demmler → South interchange).

### B. Mid-session dispatch (automatic ops cycle)

4. **Fill car orders** — Match empty/available cars to unfilled waybills.
5. **Reposition empties** — Create “E” orders for off-home empty cars (partial fraction).
6. **Auto-assign jobs** — Assign cars to D749, NVL, CK1, and other locals (staging jobs excluded).
7. **Pick up and set out** — Run pickups/setouts for assigned locals (phased mode skips staging jobs in this pass).
8. **Load / unload** — Complete instant and ready offline load/unload transitions.

### C. NVL — before CK1 (phase 1 of NVL’s day)

9. **NVL at Scully** — Assign and pick up Scully traffic on NVL.
10. **NVL Demmler setouts** — Set out Demmler-bound cars from NVL at South / offline.

### D. CK1 coke train

11. **Pick up loaded coke at Shenango** — CK1 takes loaded hoppers from the plant.
12. **Weigh at South Yard scale** — Spot train on scale track, run weigh/reload logic (track scale).
13. **Reload assignments** — Assign reload and outbound coke cars after weigh.
14. **Set out at Shenango** — Reload traffic back to the coke works.
15. **Set out at South Yard** — Outbound coke and remaining CK1 setouts.

### E. NVL — after CK1 (rest of NVL’s day)

16. **CK1 handoffs at Scully** — NVL picks up Scully-bound cars from CK1 interchange.
17. **Island / Shenango setouts** — NVL works Neville Island and Shenango deliveries.
18. **Job criterion steps** — Remaining NVL step-driven setouts (island industry spots).
19. **Demmler and Scully setouts** — Finish NVL train, clear remaining destinations.

### F. D749 — remainder of day

20. **South Yard setouts** — D749 criterion steps for South interchange.
21. **Demmler setouts** — D749 works Demmler offline spots.
22. **Island → Demmler** — Pick up island outbound for Demmler, set out at Demmler.
23. **Clear D749 train** — Remaining setouts until D749 consist is empty.

### G. Session end bookend (end of simulated day N)

24. **Finish open local work** — Mop up non-staging jobs still holding cars.
25. **STG-DEMMLER** — Run Demmler offline staging swap.
26. **D749 to Demmler** — Assign ordered cars at Demmler, pick up on D749 (**D749 on train** with inbound block).
27. **NVL to Scully** — Assign Scully pickups, pick up, set out at **Scully** (NVL secured at Scully yard).
28. **STG-SCULLY — intentionally deferred** — Cars are left **at Scully eligible for STG-SCULLY** but the job is **not** run. This mimics ending the operating session with tomorrow’s first job waiting.

During warm start, step 28 is the **stop condition**: after enough sessions (minimum 3, up to 12), the simulator stops when step 28 has produced a ready STG-SCULLY backlog.

---

## What warm start does *not* do

| Action | Warm start | begin_session |
|--------|------------|---------------|
| Increment for *next* operating session | No (only per simulated past session) | Yes (+1) |
| Fill orders for the session you are about to play | Yes, inside each simulated day | Yes, at open |
| Auto-assign for the session you are about to play | Yes, inside each simulated day | Yes, at open |
| Run STG-SCULLY for the session you are about to play | Only clears *prior* backlog at simulated day start | Yes, first action |
| Generate switch lists | No | No (separate step after begin) |

---

## End state checklist (STS user view)

After warm start completes, you should see:

- [ ] Session number = W (commonly 3).
- [ ] **STG-SCULLY**: cars at Scully / McKees Rock offline **eligible**, job not complete.
- [ ] **D749**: cars on train (Demmler block from session-end bookend).
- [ ] **NVL**: secured at Scully from bookend (not mid-route).
- [ ] Mix of filled/unfilled orders, empties, and loaded cars across the system.
- [ ] Ready to run **`begin_session`** → opens session **W+1** and is the correct point for **switch lists**.

---

## When switch lists belong (warm start context)

Switch lists are **not** captured during warm start. Warm start only establishes **history**. The first switch lists for a new campaign belong **after the first `begin_session`**, which opens session W+1.

---

## Related commands

```bash
# Tracked warm start (typical)
./bin/apply_warm_start.sh --tracked --sessions 3 --max-sessions 12

# Restore warm-start end state later
./bin/apply_hart_seed.sh --sql-file ~/sts/sts-backups/sim_warm_start
```

See also: **`BEGIN_SESSION_STEPS.md`**, **`FULL_OPERATING_SESSION.md`**.
