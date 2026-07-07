-- NVL offline pickup steps at Neville Island and South Yard

DELETE FROM `NVL` WHERE step_number IN (75, 85, 95);
INSERT INTO `NVL` (step_number, station, pickup, setout, remarks) VALUES
  (75, 3, 'T', 'F', 'Neville Island — Pick up for Demmler Offline'),
  (85, 3, 'T', 'F', 'Neville Island — Pick up for Scully Offline'),
  (95, 8, 'T', 'F', 'South Yard — Pick up for Scully Offline');

UPDATE jobs SET description = 'POHC Neville Local.
Works Scully interchange, Neville Island industries, and South Yard.
- Scully Yard: pick up and set out interchange traffic; transfer to Demmler Offline (IX) and other destinations
- Neville Island: industry spotting and pulls; outbound for Scully, Shenango, Demmler Offline, Demmler Yard, and Scully Offline
- South Yard: pick up for Scully Yard, Scully Offline, and Neville Island; set out staging'
WHERE name = 'NVL';

DELETE FROM pu_criteria WHERE job_id = 'NVL' AND step_nbr IN (75, 85, 95);
INSERT INTO pu_criteria (job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES
  ('NVL', 75, '', NULL, NULL, 14),
  ('NVL', 85, '', NULL, NULL, 15),
  ('NVL', 95, '', NULL, NULL, 15);
