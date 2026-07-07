-- Mark all STG staging steps with setouts (step 11 yard-receive setout; steps 12–50 pickup+setout at offline)

DELETE FROM `STG-SCULLY`;
INSERT INTO `STG-SCULLY` (step_number, station, pickup, setout, remarks) VALUES
  (10, 9, 'T', 'F', 'Scully Yard — Pick up for Scully Offline'),
  (11, 15, 'F', 'T', 'Scully Offline — Set out at Scully Offline'),
  (12, 15, 'T', 'T', 'Scully Offline — Pick up for Scully Offline; Set out at Scully Offline'),
  (20, 15, 'T', 'T', 'Scully Offline — Pick up for Scully Yard; Set out at Scully Offline'),
  (30, 15, 'T', 'T', 'Scully Offline — Pick up for Shenango Coke Works; Set out at Scully Offline'),
  (40, 15, 'T', 'T', 'Scully Offline — Pick up for Neville Island; Set out at Scully Offline'),
  (45, 15, 'T', 'T', 'Scully Offline — Pick up for Demmler Offline; Set out at Scully Offline'),
  (50, 15, 'T', 'T', 'Scully Offline — Pick up for Demmler Yard; Set out at Scully Offline'),
  (60, 9, 'T', 'T', 'Scully Yard — Pick up for Scully Yard; Set out at Scully Yard');

DELETE FROM `STG-DEMMLER`;
INSERT INTO `STG-DEMMLER` (step_number, station, pickup, setout, remarks) VALUES
  (10, 10, 'T', 'F', 'Demmler Yard — Pick up for Demmler Offline'),
  (11, 14, 'F', 'T', 'Demmler Offline — Set out at Demmler Offline'),
  (12, 14, 'T', 'T', 'Demmler Offline — Pick up for Demmler Offline; Set out at Demmler Offline'),
  (20, 14, 'T', 'T', 'Demmler Offline — Pick up for Scully Yard; Set out at Demmler Offline'),
  (30, 14, 'T', 'T', 'Demmler Offline — Pick up for Shenango Coke Works; Set out at Demmler Offline'),
  (40, 14, 'T', 'T', 'Demmler Offline — Pick up for Neville Island; Set out at Demmler Offline'),
  (45, 14, 'T', 'T', 'Demmler Offline — Pick up for Scully Offline; Set out at Demmler Offline'),
  (50, 14, 'T', 'T', 'Demmler Offline — Pick up for Demmler Yard; Set out at Demmler Offline'),
  (60, 10, 'T', 'T', 'Demmler Yard — Pick up for Demmler Yard; Set out at Demmler Yard');

UPDATE jobs SET description = 'Scully Yard staging — shuffle to Scully Offline, stage blocks, set out at each step.
Step 10 picks at Scully Yard; step 11 set out at Scully Offline; steps 12–50 pick and set out at Scully Offline; step 60 set out at Scully Yard.'
WHERE name = 'STG-SCULLY';

UPDATE jobs SET description = 'Demmler Yard staging — shuffle to Demmler Offline, stage blocks, set out at each step.
Step 10 picks at Demmler Yard; step 11 set out at Demmler Offline; steps 12–50 pick and set out at Demmler Offline; step 60 set out at Demmler Yard.'
WHERE name = 'STG-DEMMLER';
