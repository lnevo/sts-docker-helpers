-- Segregate offline party tracks to Demmler Offline (14) and Scully Offline (15).
-- STG-DEMMLER / STG-SCULLY: yard shuffle step then block staging at offline station.

INSERT INTO routing (id, station, station_nbr, instructions, sort_seq, color1, color2)
SELECT 14, 'Demmler Offline', l.id,
       'CSX offline party tracks at Demmler — STG-DEMMLER stages blocks after yard shuffle.',
       855, 0, 0
FROM locations l
WHERE l.code = 'DEM'
  AND NOT EXISTS (SELECT 1 FROM routing WHERE id = 14);

INSERT INTO routing (id, station, station_nbr, instructions, sort_seq, color1, color2)
SELECT 15, 'Scully Offline', l.id,
       'POHC offline party tracks at Scully — STG-SCULLY stages blocks after yard shuffle.',
       255, 0, 0
FROM locations l
WHERE l.code = 'SCL'
  AND NOT EXISTS (SELECT 1 FROM routing WHERE id = 15);

UPDATE routing
SET station = 'Demmler Offline',
    station_nbr = (SELECT id FROM locations WHERE code = 'DEM' LIMIT 1),
    instructions = 'CSX offline party tracks at Demmler — STG-DEMMLER stages blocks after yard shuffle.',
    sort_seq = 855
WHERE id = 14;

UPDATE routing
SET station = 'Scully Offline',
    station_nbr = (SELECT id FROM locations WHERE code = 'SCL' LIMIT 1),
    instructions = 'POHC offline party tracks at Scully — STG-SCULLY stages blocks after yard shuffle.',
    sort_seq = 255
WHERE id = 15;

UPDATE routing SET instructions = 'CSX interchange yard — D749 set out outbound; STG-DEMMLER shuffles to Demmler Offline.'
WHERE id = 10;
UPDATE routing SET instructions = 'POHC interchange yard — NVL set out outbound; STG-SCULLY shuffles to Scully Offline.'
WHERE id = 9;

UPDATE locations SET station = 14
WHERE track = 'OFFLINE' AND station = 10 AND code NOT IN ('DEM');
UPDATE locations SET station = 15
WHERE track = 'OFFLINE' AND station = 9 AND code NOT IN ('SCL');

DELETE FROM `STG-DEMMLER`;
INSERT INTO `STG-DEMMLER` (step_number, station, pickup, setout, remarks) VALUES
  (10, 10, 'T', 'F', 'Demmler Yard — Pick up for Demmler Offline'),
  (20, 14, 'T', 'F', 'Demmler Offline — Pick up for Scully Yard'),
  (30, 14, 'T', 'F', 'Demmler Offline — Pick up for Shenango Coke Works'),
  (40, 14, 'T', 'F', 'Demmler Offline — Pick up for Neville Island'),
  (50, 14, 'T', 'F', 'Demmler Offline — Pick up for Demmler Yard'),
  (60, 10, 'T', 'T', 'Demmler Yard — Pick up for Demmler Yard; Set out at Demmler Yard');

DELETE FROM `STG-SCULLY`;
INSERT INTO `STG-SCULLY` (step_number, station, pickup, setout, remarks) VALUES
  (10, 9, 'T', 'F', 'Scully Yard — Pick up for Scully Offline'),
  (20, 15, 'T', 'F', 'Scully Offline — Pick up for Scully Yard'),
  (30, 15, 'T', 'F', 'Scully Offline — Pick up for Shenango Coke Works'),
  (40, 15, 'T', 'F', 'Scully Offline — Pick up for Neville Island'),
  (50, 15, 'T', 'F', 'Scully Offline — Pick up for Demmler Yard'),
  (60, 9, 'T', 'T', 'Scully Yard — Pick up for Scully Yard; Set out at Scully Yard');

UPDATE jobs SET description = 'Demmler Yard staging — shuffle interchange traffic to Demmler Offline, then stage blocks.
Step 1 at Demmler Yard routes cars to offline party tracks.
Steps at Demmler Offline pick up for Scully, Shenango, Neville Island, and Demmler.'
WHERE name = 'STG-DEMMLER';

UPDATE jobs SET description = 'Scully Yard staging — shuffle interchange traffic to Scully Offline, then stage blocks.
Step 1 at Scully Yard routes cars to offline party tracks.
Steps at Scully Offline pick up for Scully, Shenango, Neville Island, and Demmler.'
WHERE name = 'STG-SCULLY';

DELETE FROM pu_criteria WHERE job_id IN ('STG-DEMMLER', 'STG-SCULLY');
INSERT INTO pu_criteria (job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES
  ('STG-SCULLY', 10, '', NULL, NULL, 15),
  ('STG-SCULLY', 20, '', NULL, NULL, 9),
  ('STG-SCULLY', 30, '', NULL, NULL, 12),
  ('STG-SCULLY', 40, '', NULL, NULL, 3),
  ('STG-SCULLY', 50, '', NULL, NULL, 10),
  ('STG-SCULLY', 60, '', NULL, NULL, 9),
  ('STG-DEMMLER', 10, '', NULL, NULL, 14),
  ('STG-DEMMLER', 20, '', NULL, NULL, 9),
  ('STG-DEMMLER', 30, '', NULL, NULL, 12),
  ('STG-DEMMLER', 40, '', NULL, NULL, 3),
  ('STG-DEMMLER', 50, '', NULL, NULL, 10),
  ('STG-DEMMLER', 60, '', NULL, NULL, 10);
