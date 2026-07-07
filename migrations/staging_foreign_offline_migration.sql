-- Add step 45 to staging jobs: foreign offline IX destinations
-- STG-DEMMLER @ Demmler Offline → Scully Offline (15)
-- STG-SCULLY @ Scully Offline → Demmler Offline (14)

DELETE FROM `STG-DEMMLER`;
INSERT INTO `STG-DEMMLER` (step_number, station, pickup, setout, remarks) VALUES
  (10, 10, 'T', 'F', 'Demmler Yard — Pick up for Demmler Offline'),
  (20, 14, 'T', 'F', 'Demmler Offline — Pick up for Scully Yard'),
  (30, 14, 'T', 'F', 'Demmler Offline — Pick up for Shenango Coke Works'),
  (40, 14, 'T', 'F', 'Demmler Offline — Pick up for Neville Island'),
  (45, 14, 'T', 'F', 'Demmler Offline — Pick up for Scully Offline'),
  (50, 14, 'T', 'F', 'Demmler Offline — Pick up for Demmler Yard'),
  (60, 10, 'T', 'T', 'Demmler Yard — Pick up for Demmler Yard; Set out at Demmler Yard');

DELETE FROM `STG-SCULLY`;
INSERT INTO `STG-SCULLY` (step_number, station, pickup, setout, remarks) VALUES
  (10, 9, 'T', 'F', 'Scully Yard — Pick up for Scully Offline'),
  (20, 15, 'T', 'F', 'Scully Offline — Pick up for Scully Yard'),
  (30, 15, 'T', 'F', 'Scully Offline — Pick up for Shenango Coke Works'),
  (40, 15, 'T', 'F', 'Scully Offline — Pick up for Neville Island'),
  (45, 15, 'T', 'F', 'Scully Offline — Pick up for Demmler Offline'),
  (50, 15, 'T', 'F', 'Scully Offline — Pick up for Demmler Yard'),
  (60, 9, 'T', 'T', 'Scully Yard — Pick up for Scully Yard; Set out at Scully Yard');

UPDATE jobs SET description = 'Demmler Yard staging — shuffle interchange traffic to Demmler Offline, then stage blocks.
Step 1 at Demmler Yard routes cars to offline party tracks.
Steps at Demmler Offline pick up for Scully, Shenango, Neville Island, Scully Offline (IX), and Demmler Yard.'
WHERE name = 'STG-DEMMLER';

UPDATE jobs SET description = 'Scully Yard staging — shuffle interchange traffic to Scully Offline, then stage blocks.
Step 1 at Scully Yard routes cars to offline party tracks.
Steps at Scully Offline pick up for Scully, Shenango, Neville Island, Demmler Offline (IX), and Demmler Yard.'
WHERE name = 'STG-SCULLY';

DELETE FROM pu_criteria WHERE job_id IN ('STG-DEMMLER', 'STG-SCULLY');
INSERT INTO pu_criteria (job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES
  ('STG-SCULLY', 10, '', NULL, NULL, 15),
  ('STG-SCULLY', 20, '', NULL, NULL, 9),
  ('STG-SCULLY', 30, '', NULL, NULL, 12),
  ('STG-SCULLY', 40, '', NULL, NULL, 3),
  ('STG-SCULLY', 45, '', NULL, NULL, 14),
  ('STG-SCULLY', 50, '', NULL, NULL, 10),
  ('STG-SCULLY', 60, '', NULL, NULL, 9),
  ('STG-DEMMLER', 10, '', NULL, NULL, 14),
  ('STG-DEMMLER', 20, '', NULL, NULL, 9),
  ('STG-DEMMLER', 30, '', NULL, NULL, 12),
  ('STG-DEMMLER', 40, '', NULL, NULL, 3),
  ('STG-DEMMLER', 45, '', NULL, NULL, 15),
  ('STG-DEMMLER', 50, '', NULL, NULL, 10),
  ('STG-DEMMLER', 60, '', NULL, NULL, 10);
