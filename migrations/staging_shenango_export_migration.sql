-- Staging: Shenango coke export — pick up Loaded at Shenango for Demmler (70) and Scully (80).

DELETE FROM pu_criteria WHERE job_id = 'Staging' AND step_nbr IN (70, 80);
DELETE FROM Staging WHERE step_number IN (70, 80);

INSERT INTO Staging (step_number, station, pickup, setout, remarks) VALUES
(70, 12, 'T', 'T', 'Shenango Coke Works — pick up coke for Demmler Yard export'),
(80, 12, 'T', 'T', 'Shenango Coke Works — pick up coke for Scully Yard export');

INSERT INTO pu_criteria (job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES
('Staging', 70, 'Loaded', 0, 0, 10),
('Staging', 80, 'Loaded', 0, 0, 9);

UPDATE jobs
SET description = 'Transfer cars between interchange yards, Shenango Coke Works, and offline load/unload tracks.
- Scully Yard: pick up for Scully, Neville Island, and Demmler (steps 10–30)
- Demmler Yard: pick up for Demmler, Neville Island, and Scully (steps 40–60)
- Shenango Coke Works: pick up loaded coke for Demmler export (70), Scully export (80), and South Yard scale (90)'
WHERE name = 'Staging';

UPDATE routing
SET instructions = 'Coke plant on Neville Island — separate routing station.
Coke fleet home and load point; Staging export to Scully and Demmler.'
WHERE id = 12;
