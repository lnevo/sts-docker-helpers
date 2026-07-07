-- Staging: Shenango step 90 — Loaded coke pickup for South Yard scale (station 8).

DELETE FROM Staging WHERE step_number = 90;
INSERT INTO Staging (step_number, station, pickup, setout, remarks) VALUES
(90, 12, 'T', 'T', 'Shenango Coke Works — pick up coke for South Yard scale');

DELETE FROM pu_criteria WHERE job_id = 'Staging' AND step_nbr = 90;
INSERT INTO pu_criteria (job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id)
VALUES ('Staging', 90, 'Loaded', 0, 0, 8);

UPDATE jobs
SET description = 'Transfer cars between interchange yards, Shenango Coke Works, and offline load/unload tracks.
- Scully Yard: pick up for Scully, Neville Island, and Demmler (steps 10–30)
- Demmler Yard: pick up for Demmler, Neville Island, and Scully (steps 40–60)
- Shenango Coke Works: pick up loaded coke for Demmler export (70), Scully export (80), and South Yard scale (90)'
WHERE name = 'Staging';
