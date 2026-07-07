-- D749 South Yard pickup for Demmler Offline (IX transfer from classification)

DELETE FROM `D749` WHERE step_number = 15;
INSERT INTO `D749` (step_number, station, pickup, setout, remarks) VALUES
  (15, 8, 'T', 'F', 'South Yard — Pick up for Demmler Offline');

UPDATE jobs SET description = 'CSX Neville Island Switcher.
Works South Yard and CSX Demmler interchange.
- South Yard: set out inbound; pick up for Demmler Yard and Demmler Offline
- Demmler Yard: pick up inbound and offline for Scully, Scully Offline (IX transfer), Shenango, Neville Island, and Demmler; set out outbound'
WHERE name = 'D749';

DELETE FROM pu_criteria WHERE job_id = 'D749' AND step_nbr = 15;
INSERT INTO pu_criteria (job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES
  ('D749', 15, '', NULL, NULL, 14);
