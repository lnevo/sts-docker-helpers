-- D749/NVL: remove Shenango steps; YM1: add East Yard; all jobs dest-only pu_criteria.

DELETE FROM pu_criteria WHERE job_id IN ('D749', 'NVL', 'YM1', 'CK1');

-- D749: drop Shenango steps, renumber South Yard / Demmler setout.
DELETE FROM D749 WHERE step_number IN (35, 40);
UPDATE D749 SET step_number = 99 WHERE step_number = 50;
UPDATE D749 SET step_number = 98 WHERE step_number = 60;
UPDATE D749 SET step_number = 40 WHERE step_number = 99;
UPDATE D749 SET step_number = 50 WHERE step_number = 98;

-- NVL: drop Shenango steps, renumber Scully setout.
DELETE FROM NVL WHERE step_number IN (35, 70);
UPDATE NVL SET step_number = 70 WHERE step_number = 75;

-- YM1: add East Yard block; renumber South setout to 110.
UPDATE YM1 SET step_number = 110 WHERE step_number = 70;
DELETE FROM YM1 WHERE step_number IN (70, 80, 90, 100);
INSERT INTO YM1 (step_number, station, pickup, setout, remarks) VALUES
(70, 13, 'T', 'T', 'Retrieve and stage cars at East Yard'),
(80, 13, 'T', 'F', 'Pick up East Yard cars for Demmler Yard'),
(90, 13, 'T', 'F', 'Pick up East Yard cars for Scully Yard'),
(100, 13, 'T', 'T', 'Retrieve and stage cars at East Yard');

INSERT INTO pu_criteria (job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES
('D749', 10, '', NULL, NULL, 9),
('D749', 20, '', NULL, NULL, 3),
('D749', 30, '', NULL, NULL, 10),
('D749', 40, '', NULL, NULL, 10),
('NVL', 10, '', NULL, NULL, 3),
('NVL', 20, '', NULL, NULL, 10),
('NVL', 30, '', NULL, NULL, 9),
('NVL', 40, '', NULL, NULL, 3),
('NVL', 50, '', NULL, NULL, 3),
('NVL', 50, '', NULL, NULL, 9),
('NVL', 50, '', NULL, NULL, 10),
('NVL', 60, '', NULL, NULL, 9),
('YM1', 10, '', NULL, NULL, 3),
('YM1', 10, '', NULL, NULL, 9),
('YM1', 10, '', NULL, NULL, 10),
('YM1', 10, '', NULL, NULL, 13),
('YM1', 20, '', NULL, NULL, 3),
('YM1', 20, '', NULL, NULL, 8),
('YM1', 30, '', NULL, NULL, 10),
('YM1', 40, '', NULL, NULL, 9),
('YM1', 50, '', NULL, NULL, 3),
('YM1', 50, '', NULL, NULL, 8),
('YM1', 60, '', NULL, NULL, 3),
('YM1', 60, '', NULL, NULL, 8),
('YM1', 70, '', NULL, NULL, 3),
('YM1', 70, '', NULL, NULL, 8),
('YM1', 80, '', NULL, NULL, 10),
('YM1', 90, '', NULL, NULL, 9),
('YM1', 100, '', NULL, NULL, 3),
('YM1', 100, '', NULL, NULL, 8),
('CK1', 10, '', NULL, NULL, 8),
('CK1', 20, '', NULL, NULL, 10),
('CK1', 30, '', NULL, NULL, 9),
('CK1', 40, '', NULL, NULL, 11);

UPDATE jobs
SET description = 'CSX Neville Island Switcher.
- Demmler Yard: Pick up for Scully Yard
- Demmler Yard: Pick up for Neville Island
- Demmler Yard: Pick up cars loading at Demmler (inbound / interchange)
- South Yard: Set out inbound; Pick up for Demmler Yard
- Demmler Yard: Set out outbound'
WHERE name = 'D749';

UPDATE jobs
SET description = 'POHC Neville Local.
- Scully Yard: Pick up for Neville Island and Demmler Yard
- Scully Yard: Pick up cars loading at Scully (inbound / interchange)
- South Yard: Set out; Pick up Neville Island block
- Neville Island: Spot and pull for island, Scully, and Demmler
- South Yard: Set out; Pick up for Scully Yard
- Scully Yard: Set out outbound'
WHERE name = 'NVL';

UPDATE jobs
SET description = 'South Yard yardmaster (YM1) — inter-island switching on Neville Island.
Retrieve and stage cars across North, West, and East yards for island industries.
Sort inbound traffic and build outbound blocks for CSX D749 (via Demmler) and POHC NVL (via Scully).
D749 and NVL handle industry spotting and interchange; YM1 works the satellite yards only.'
WHERE name = 'YM1';
