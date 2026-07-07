-- Move coke fleet, shipments, jobs, and pickup criteria from East Yard to North Yard.

-- Coke fleet: current and home locations
UPDATE cars c
INNER JOIN locations east ON east.code = 'EAST-YARD'
INNER JOIN locations north ON north.code = 'NORTH-YARD'
SET c.current_location_id = north.id,
    c.home_location = north.id
WHERE c.current_location_id = east.id
   OR c.home_location = east.id;

-- Outbound coke shipments load at North Yard
UPDATE shipments s
INNER JOIN locations east ON east.code = 'EAST-YARD'
INNER JOIN locations north ON north.code = 'NORTH-YARD'
SET s.loading_location = north.id
WHERE s.loading_location = east.id
  AND s.code IN ('COKE-USS', 'COKE-CLEV', 'COKE-USS-BULK', 'COKE-CLEV-BULK');

-- Reload shipment: rename and unload at North Yard
UPDATE shipments s
INNER JOIN locations east ON east.code = 'EAST-YARD'
INNER JOIN locations north ON north.code = 'NORTH-YARD'
SET s.code = 'COKE-RELOAD-NORTH',
    s.description = 'South Yard Scale to North Yard',
    s.unloading_location = north.id
WHERE s.code = 'COKE-RELOAD-EAST';

-- YM1 job steps @ North Yard (was East Yard station 12)
UPDATE YM1 SET station = 11, remarks = 'Pick up North Yard cars for Demmler Yard' WHERE step_number = 30;
UPDATE YM1 SET station = 11, remarks = 'Pick up North Yard cars for Scully Yard' WHERE step_number = 40;
UPDATE YM1 SET station = 11, remarks = 'Retrieve and stage cars at North Yard' WHERE step_number = 50;

-- CK1 job steps @ North Yard
UPDATE CK1 SET station = 11, remarks = 'Pick up coke loads at North Yard for South Yard weighing' WHERE step_number = 10;
UPDATE CK1 SET station = 11, remarks = 'Pick up North Yard coke for Demmler Yard' WHERE step_number = 20;
UPDATE CK1 SET station = 11, remarks = 'Pick up North Yard coke for Scully Yard' WHERE step_number = 30;
UPDATE CK1 SET remarks = 'Pick up South Yard coke for North Yard reload' WHERE step_number = 40;

UPDATE jobs
SET description = 'Coke transfer — optional yard move.
Move coke loads from North Yard to South Yard for weighing and classification when authorized and traffic warrants.
Pick up Demmler- and Scully-bound coke at North Yard on separate steps (same pattern as YM1).
Pick up North Yard-bound reloads at South Yard before setout.
Run only when it will not interfere with NVL or passenger movements.'
WHERE name = 'CK1';

UPDATE jobs
SET description = 'South Yard yardmaster (YM1) — inter-island switching on Neville Island.
Retrieve and stage cars across North and West yards for island industries.
Sort inbound traffic and build outbound blocks for CSX D749 (via Demmler) and POHC NVL (via Scully).
D749 and NVL handle industry spotting and interchange; YM1 works the satellite yards only.'
WHERE name = 'YM1';

-- CK1 step 40: pick up reloads bound for North Yard
UPDATE pu_criteria
SET dest_station_id = 11
WHERE job_id = 'CK1' AND step_nbr = 40 AND dest_station_id = 12;

-- North Yard routing instructions (coke storage moved from East Yard)
UPDATE routing
SET instructions = 'YM1 yardmaster staging.
Coke storage — CK1 to South Yard when authorized.
Cars for island industries or South Yard classification.'
WHERE id = 11;

-- Retire East Yard routing station and location
DELETE FROM locations WHERE code = 'EAST-YARD';
DELETE FROM routing WHERE id = 12;
