-- NVL: Scully (not Demmler) pickup for Shenango coke orders.

DELETE FROM pu_criteria WHERE job_id = 'NVL' AND step_nbr IN (65, 70);
DELETE FROM NVL WHERE step_number = 65;

INSERT INTO NVL (step_number, station, pickup, setout, remarks) VALUES
(35, 9, 'T', 'F', 'Pick up coke orders for Shenango Coke Works');

INSERT INTO pu_criteria (job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES
('NVL', 35, 'Ordered', NULL, NULL, 12),
('NVL', 70, 'Loaded', NULL, NULL, 9);

UPDATE jobs
SET description = 'POHC Neville Local.
- Scully Yard: Pick up for Neville Island and Demmler Yard
- Scully Yard: Pick up cars loading at Scully (inbound / interchange)
- Scully Yard: Pick up coke orders for Shenango Coke Works
- South Yard: Set out; Pick up Neville Island block
- Neville Island: Spot and pull for island, Scully, and Demmler
- South Yard: Set out; Pick up for Scully Yard
- Shenango Coke Works: Set out; pick up loaded coke for Scully export
- Scully Yard: Set out outbound'
WHERE name = 'NVL';
