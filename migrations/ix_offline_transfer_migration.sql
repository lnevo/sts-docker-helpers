-- IX cross-interchange offline transfers on locals (not staging jobs)
-- D749 @ Demmler Yard → Scully Offline (15)
-- NVL @ Scully Yard → Demmler Offline (14)

DELETE FROM `D749` WHERE step_number = 35;
INSERT INTO `D749` (step_number, station, pickup, setout, remarks) VALUES
  (35, 10, 'T', 'F', 'Demmler Yard — Pick up for Scully Offline');

DELETE FROM `NVL` WHERE step_number = 35;
INSERT INTO `NVL` (step_number, station, pickup, setout, remarks) VALUES
  (35, 9, 'T', 'F', 'Scully Yard — Pick up for Demmler Offline');

UPDATE jobs SET description = 'CSX Neville Island Switcher.
Works South Yard and CSX Demmler interchange.
- Demmler Yard: pick up inbound and offline for Scully, Scully Offline (IX transfer), Shenango, Neville Island, and Demmler; set out outbound
- South Yard: set out inbound; pick up for Demmler'
WHERE name = 'D749';

UPDATE jobs SET description = 'POHC Neville Local.
Works Scully interchange, Neville Island industries, and South Yard.
- Scully Yard: pick up and set out interchange traffic; transfer to Demmler Offline (IX) and other destinations
- Neville Island: industry spotting and pulls for Scully, Shenango, island, and Demmler
- South Yard: pick up blocks for Scully and island; set out staging'
WHERE name = 'NVL';

DELETE FROM pu_criteria WHERE job_id = 'D749' AND step_nbr = 35;
INSERT INTO pu_criteria (job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES
  ('D749', 35, '', NULL, NULL, 15);

DELETE FROM pu_criteria WHERE job_id = 'NVL' AND step_nbr = 35;
INSERT INTO pu_criteria (job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES
  ('NVL', 35, '', NULL, NULL, 14);
