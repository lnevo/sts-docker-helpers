-- Remove redundant Staging step 110 (Shenango setout covered by steps 70–90).

DELETE FROM Staging WHERE step_number = 110;

UPDATE jobs
SET description = 'Transfer cars between interchange yards, Shenango Coke Works, and offline load/unload tracks.
- Scully Yard: pick up for Scully, Neville Island, and Demmler (steps 10–30)
- Demmler Yard: pick up for Demmler, Neville Island, and Scully (steps 40–60)
- Shenango Coke Works: pick up loaded coke for Demmler export (70), Scully export (80), and South Yard scale (90)
- North Yard: pick up pending loads for Shenango (100)'
WHERE name = 'Staging';
