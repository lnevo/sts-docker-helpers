-- CK1: South Yard pickup for East Yard-bound coke (step 40); setout renumbered to 50.

DELETE FROM pu_criteria WHERE job_id = 'CK1';

DELETE FROM CK1;

INSERT INTO CK1 (step_number, station, pickup, setout, remarks) VALUES
(10, 12, 'T', 'F', 'Pick up coke loads at East Yard for South Yard weighing'),
(20, 12, 'T', 'F', 'Pick up East Yard coke for Demmler Yard'),
(30, 12, 'T', 'F', 'Pick up East Yard coke for Scully Yard'),
(40, 8, 'T', 'F', 'Pick up South Yard coke for East Yard reload'),
(50, 8, 'F', 'T', 'Set out coke loads at South Yard for weighing/classification');

INSERT INTO pu_criteria (job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES
('CK1', 10, 'Loaded', NULL, NULL, 8),
('CK1', 20, 'Loaded', NULL, NULL, 10),
('CK1', 30, 'Loaded', NULL, NULL, 9),
('CK1', 40, 'Loaded', NULL, NULL, 12);
