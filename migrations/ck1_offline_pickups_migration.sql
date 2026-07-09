-- CK1: Shenango coke export pickups for McKees Rocks-PA (15) and Mckeesport-PA (14).
-- Job steps 70 / 100 at Shenango Coke Works (station 12).

UPDATE pu_criteria SET dest_station_id = 15 WHERE job_id = 'CK1' AND step_nbr = 70;
UPDATE pu_criteria SET dest_station_id = 14 WHERE job_id = 'CK1' AND step_nbr = 100;
