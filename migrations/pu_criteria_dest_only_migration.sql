-- Pickup criteria: dest_station only (clear car_status except CK1 Loaded coke).

UPDATE pu_criteria SET car_status = ''
WHERE job_id IN ('D749', 'NVL', 'STG1', 'STG2', 'STG3', 'YM1');

-- CK1 remains Loaded-only (coke transfer job).
