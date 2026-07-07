-- YM1: discrete East Yard pickups for Demmler (step 30) and Scully (step 40); steps by 10.

DELETE FROM pu_criteria WHERE job_id = 'YM1';

DELETE FROM YM1;

INSERT INTO YM1 (step_number, station, pickup, setout, remarks) VALUES
(10, 8, 'T', 'F', 'Pick up inbound cars from D749 and NVL for classification'),
(20, 11, 'T', 'T', 'Retrieve and stage cars at North Yard'),
(30, 12, 'T', 'F', 'Pick up East Yard cars for Demmler Yard'),
(40, 12, 'T', 'F', 'Pick up East Yard cars for Scully Yard'),
(50, 12, 'T', 'T', 'Retrieve and stage cars at East Yard'),
(60, 2, 'T', 'T', 'Retrieve and stage cars at West Yard'),
(70, 8, 'F', 'T', 'Build NVL industry block; stage CSX block for D749 (Demmler) and POHC block for NVL (Scully)');

INSERT INTO pu_criteria (job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES
('YM1', 10, '', NULL, NULL, 3),
('YM1', 10, '', NULL, NULL, 10),
('YM1', 10, '', NULL, NULL, 9),
('YM1', 20, '', NULL, NULL, 3),
('YM1', 20, '', NULL, NULL, 8),
('YM1', 30, '', NULL, NULL, 10),
('YM1', 40, '', NULL, NULL, 9),
('YM1', 50, '', NULL, NULL, 3),
('YM1', 50, '', NULL, NULL, 8),
('YM1', 60, '', NULL, NULL, 3),
('YM1', 60, '', NULL, NULL, 8);
