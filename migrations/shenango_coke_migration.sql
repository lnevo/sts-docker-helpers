-- Shenango Coke Works: own routing station on Neville Island; coke loads and fleet home.
-- Staging job steps 70/80: Loaded coke export from Shenango to Demmler and Scully.

INSERT INTO locations (code, station, track, spot, rpt_station, remarks)
SELECT 'NIL-SHEN-COKE', 12, 'OUTBOUND', 'OUT', 'Neville Island', 'Shenango Coke Works'
WHERE NOT EXISTS (SELECT 1 FROM locations WHERE code = 'NIL-SHEN-COKE');

INSERT INTO routing (id, station, station_nbr, instructions, sort_seq, color1, color2)
SELECT 12, 'Shenango Coke Works', l.id,
       'Coke plant on Neville Island — separate routing station.\nCoke fleet home and load point; Staging export to Scully and Demmler.',
       290, 0, 0
FROM locations l
WHERE l.code = 'NIL-SHEN-COKE'
  AND NOT EXISTS (SELECT 1 FROM routing WHERE id = 12);

UPDATE routing
SET station = 'Shenango Coke Works',
    station_nbr = (SELECT id FROM locations WHERE code = 'NIL-SHEN-COKE' LIMIT 1),
    instructions = 'Coke plant on Neville Island — separate routing station.\nCoke fleet home and load point; Staging export to Scully and Demmler.',
    sort_seq = 290
WHERE id = 12;

UPDATE locations
SET track = 'OUTBOUND', spot = 'OUT'
WHERE code = 'NIL-SHEN-COKE';

-- Outbound coke shipments load at Shenango
UPDATE shipments s
INNER JOIN locations shen ON shen.code = 'NIL-SHEN-COKE'
SET s.loading_location = shen.id
WHERE s.code IN ('COKE-USS', 'COKE-CLEV', 'COKE-USS-BULK', 'COKE-CLEV-BULK');

-- Coke fleet home and current location (pool-linked HM hoppers)
UPDATE cars c
INNER JOIN pool p ON p.car_id = c.id
INNER JOIN shipments s ON s.id = p.shipment_id
    AND s.code IN ('COKE-USS', 'COKE-CLEV', 'COKE-USS-BULK', 'COKE-CLEV-BULK')
INNER JOIN locations shen ON shen.code = 'NIL-SHEN-COKE'
SET c.current_location_id = shen.id,
    c.home_location = shen.id;

-- Staging job: Shenango coke export
DELETE FROM Staging WHERE step_number IN (70, 80);
INSERT INTO Staging (step_number, station, pickup, setout, remarks) VALUES
(70, 12, 'T', 'T', 'Shenango Coke Works — pick up coke for Demmler Yard export'),
(80, 12, 'T', 'T', 'Shenango Coke Works — pick up coke for Scully Yard export'),
(90, 12, 'T', 'T', 'Shenango Coke Works — pick up coke for South Yard scale');

DELETE FROM pu_criteria WHERE job_id = 'Staging' AND step_nbr IN (70, 80, 90);
INSERT INTO pu_criteria (job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES
('Staging', 70, 'Loaded', 0, 0, 10),
('Staging', 80, 'Loaded', 0, 0, 9),
('Staging', 90, 'Loaded', 0, 0, 8);

UPDATE jobs
SET description = 'Transfer cars between interchange yards, Shenango Coke Works, and offline load/unload tracks.
- Scully Yard: pick up for Scully, Neville Island, and Demmler (steps 10–30)
- Demmler Yard: pick up for Demmler, Neville Island, and Scully (steps 40–60)
- Shenango Coke Works: pick up loaded coke for Demmler export (70), Scully export (80), and South Yard scale (90)'
WHERE name = 'Staging';

UPDATE routing
SET instructions = 'YM1 yardmaster staging.
Outbound coke staging — CK1 to South Yard when authorized.
Cars for island industries or South Yard classification.'
WHERE id = 11;
