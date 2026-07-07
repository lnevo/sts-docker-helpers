-- Staging job: one step per destination (10–90 by tens).
-- Scully Yard (9): 10→Scully, 20→Neville Island, 30→Demmler
-- Demmler Yard (10): 40→Demmler, 50→Neville Island, 60→Scully
-- Shenango Coke Works (12): 70→Demmler export, 80→Scully export, 90→South Yard scale (Loaded coke)

DELETE FROM pu_criteria WHERE job_id = 'Staging';
DELETE FROM Staging;

INSERT INTO Staging (step_number, station, pickup, setout, remarks) VALUES
(10, 9, 'T', 'T', 'Scully Yard — pick up for Scully Yard'),
(20, 9, 'T', 'T', 'Scully Yard — pick up for Neville Island'),
(30, 9, 'T', 'T', 'Scully Yard — pick up for Demmler Yard'),
(40, 10, 'T', 'T', 'Demmler Yard — pick up for Demmler Yard'),
(50, 10, 'T', 'T', 'Demmler Yard — pick up for Neville Island'),
(60, 10, 'T', 'T', 'Demmler Yard — pick up for Scully Yard'),
(70, 12, 'T', 'T', 'Shenango Coke Works — pick up coke for Demmler Yard export'),
(80, 12, 'T', 'T', 'Shenango Coke Works — pick up coke for Scully Yard export'),
(90, 12, 'T', 'T', 'Shenango Coke Works — pick up coke for South Yard scale'),
(100, 11, 'T', 'T', 'North Yard — pick up pending loads for Shenango Coke Works');

INSERT INTO pu_criteria (job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES
('Staging', 10, '', 0, 0, 9),
('Staging', 20, '', 0, 0, 3),
('Staging', 30, '', 0, 0, 10),
('Staging', 40, '', 0, 0, 10),
('Staging', 50, '', 0, 0, 3),
('Staging', 60, '', 0, 0, 9),
('Staging', 70, 'Loaded', 0, 0, 10),
('Staging', 80, 'Loaded', 0, 0, 9),
('Staging', 90, 'Loaded', 0, 0, 8),
('Staging', 100, 'Ordered', 0, 0, 12);

UPDATE jobs SET description = 'Transfer cars between interchange yards, Shenango Coke Works, and offline load/unload tracks.
- Scully Yard: pick up for Scully, Neville Island, and Demmler (steps 10–30)
- Demmler Yard: pick up for Demmler, Neville Island, and Scully (steps 40–60)
- Shenango Coke Works: pick up loaded coke for Demmler export (70), Scully export (80), and South Yard scale (90)
- North Yard: pick up pending loads for Shenango (100)'
WHERE name = 'Staging';

UPDATE routing
SET instructions = 'Coke plant on Neville Island — separate routing station.
Coke fleet home and load point; Staging export to Scully and Demmler.'
WHERE id = 12;
