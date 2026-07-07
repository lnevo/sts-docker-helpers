-- D749 / NVL: Demmler ↔ Shenango Coke Works coke transfer steps.

DELETE FROM pu_criteria WHERE job_id IN ('D749', 'NVL');

-- D749: renumber South Yard and Demmler setout; add Shenango steps.
UPDATE D749 SET step_number = 60 WHERE step_number = 50;
UPDATE D749 SET step_number = 50 WHERE step_number = 40;

DELETE FROM D749 WHERE step_number IN (35, 40);
INSERT INTO D749 (step_number, station, pickup, setout, remarks) VALUES
(35, 10, 'T', 'F', 'Pick up coke orders for Shenango Coke Works'),
(40, 12, 'T', 'T', 'Shenango Coke Works — setout; pick up loaded coke for Demmler export');

-- NVL: renumber Scully setout; add Demmler → Shenango steps.
UPDATE NVL SET step_number = 75 WHERE step_number = 70;

DELETE FROM NVL WHERE step_number IN (65, 70);
INSERT INTO NVL (step_number, station, pickup, setout, remarks) VALUES
(65, 10, 'T', 'F', 'Pick up coke orders for Shenango Coke Works'),
(70, 12, 'T', 'T', 'Shenango Coke Works — setout; pick up loaded coke for Scully export');

INSERT INTO pu_criteria (job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES
('D749', 10, '', NULL, NULL, 9),
('D749', 20, '', NULL, NULL, 3),
('D749', 30, '', NULL, NULL, 10),
('D749', 35, 'Ordered', NULL, NULL, 12),
('D749', 40, 'Loaded', NULL, NULL, 10),
('D749', 50, '', NULL, NULL, 10),
('NVL', 10, '', NULL, NULL, 3),
('NVL', 20, '', NULL, NULL, 10),
('NVL', 30, '', NULL, NULL, 9),
('NVL', 40, '', NULL, NULL, 3),
('NVL', 50, '', NULL, NULL, 3),
('NVL', 50, '', NULL, NULL, 9),
('NVL', 50, '', NULL, NULL, 10),
('NVL', 60, '', NULL, NULL, 9),
('NVL', 65, 'Ordered', NULL, NULL, 12),
('NVL', 70, 'Loaded', NULL, NULL, 9);

UPDATE jobs
SET description = 'CSX Neville Island Switcher.
- Demmler Yard: Pick up for Scully Yard
- Demmler Yard: Pick up for Neville Island
- Demmler Yard: Pick up cars loading at Demmler (inbound / interchange)
- Demmler Yard: Pick up coke orders for Shenango Coke Works
- Shenango Coke Works: Set out; pick up loaded coke for Demmler export
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
- Demmler Yard: Pick up coke orders for Shenango Coke Works
- Shenango Coke Works: Set out; pick up loaded coke for Scully export
- Scully Yard: Set out outbound'
WHERE name = 'NVL';
