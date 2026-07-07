-- CK1: North/Shenango coke export to offline stations; drop South Yard Scully/Demmler pickups

UPDATE `CK1` SET remarks = 'North Yard — Pick up for Scully Offline' WHERE step_number = 20;
UPDATE `CK1` SET remarks = 'North Yard — Pick up for Demmler Offline' WHERE step_number = 50;
UPDATE `CK1` SET remarks = 'Shenango Coke Works — Pick up for Scully Offline' WHERE step_number = 70;
UPDATE `CK1` SET remarks = 'Shenango Coke Works — Pick up for Demmler Offline' WHERE step_number = 100;

DELETE FROM `CK1` WHERE step_number IN (120, 140);

UPDATE jobs SET description = 'Coke transfer — optional yard move.
Move coke loads between Shenango Coke Works, North Yard, and South Yard for weighing and classification when authorized.
North Yard and Shenango export coke to Demmler Offline and Scully Offline; South Yard picks for North Yard and Shenango only.'
WHERE name = 'CK1';

UPDATE pu_criteria SET dest_station_id = 15 WHERE job_id = 'CK1' AND step_nbr = 20;
UPDATE pu_criteria SET dest_station_id = 14 WHERE job_id = 'CK1' AND step_nbr = 50;
UPDATE pu_criteria SET dest_station_id = 15 WHERE job_id = 'CK1' AND step_nbr = 70;
UPDATE pu_criteria SET dest_station_id = 14 WHERE job_id = 'CK1' AND step_nbr = 100;
DELETE FROM pu_criteria WHERE job_id = 'CK1' AND step_nbr IN (120, 140);
