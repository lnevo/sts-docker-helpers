-- Apply matrix-derived job rules to live STS database.
-- Generated from hart_job_criteria_matrix.xlsx via import_hart_job_matrix.py

DELETE FROM pu_criteria;

DELETE FROM `D749`;
INSERT INTO `D749` (step_number, station, pickup, setout, remarks) VALUES (10, 8, 'T', 'F', 'South Yard — Pick up for Demmler Yard');
INSERT INTO `D749` (step_number, station, pickup, setout, remarks) VALUES (20, 8, 'F', 'T', 'South Yard — Set out at South Yard');
INSERT INTO `D749` (step_number, station, pickup, setout, remarks) VALUES (30, 10, 'T', 'F', 'Demmler Yard — Pick up for Scully Yard');
INSERT INTO `D749` (step_number, station, pickup, setout, remarks) VALUES (40, 10, 'T', 'F', 'Demmler Yard — Pick up for Shenango Coke Works');
INSERT INTO `D749` (step_number, station, pickup, setout, remarks) VALUES (50, 10, 'T', 'F', 'Demmler Yard — Pick up for Neville Island');
INSERT INTO `D749` (step_number, station, pickup, setout, remarks) VALUES (60, 10, 'T', 'T', 'Demmler Yard — Pick up for Demmler Yard; Set out at Demmler Yard');

DELETE FROM `NVL`;
INSERT INTO `NVL` (step_number, station, pickup, setout, remarks) VALUES (10, 9, 'T', 'T', 'Scully Yard — Pick up for Scully Yard; Set out at Scully Yard');
INSERT INTO `NVL` (step_number, station, pickup, setout, remarks) VALUES (20, 9, 'T', 'F', 'Scully Yard — Pick up for Shenango Coke Works');
INSERT INTO `NVL` (step_number, station, pickup, setout, remarks) VALUES (30, 9, 'T', 'F', 'Scully Yard — Pick up for Neville Island');
INSERT INTO `NVL` (step_number, station, pickup, setout, remarks) VALUES (40, 9, 'T', 'F', 'Scully Yard — Pick up for Demmler Yard');
INSERT INTO `NVL` (step_number, station, pickup, setout, remarks) VALUES (50, 3, 'T', 'F', 'Neville Island — Pick up for Scully Yard');
INSERT INTO `NVL` (step_number, station, pickup, setout, remarks) VALUES (60, 3, 'T', 'F', 'Neville Island — Pick up for Shenango Coke Works');
INSERT INTO `NVL` (step_number, station, pickup, setout, remarks) VALUES (70, 3, 'T', 'T', 'Neville Island — Pick up for Neville Island; Set out at Neville Island');
INSERT INTO `NVL` (step_number, station, pickup, setout, remarks) VALUES (80, 3, 'T', 'F', 'Neville Island — Pick up for Demmler Yard');
INSERT INTO `NVL` (step_number, station, pickup, setout, remarks) VALUES (90, 8, 'T', 'F', 'South Yard — Pick up for Scully Yard');
INSERT INTO `NVL` (step_number, station, pickup, setout, remarks) VALUES (100, 8, 'T', 'F', 'South Yard — Pick up for Neville Island');
INSERT INTO `NVL` (step_number, station, pickup, setout, remarks) VALUES (110, 8, 'F', 'T', 'South Yard — Set out at South Yard');

DELETE FROM `YM1`;
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (10, 11, 'T', 'F', 'North Yard — Pick up for Scully Yard');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (20, 11, 'T', 'F', 'North Yard — Pick up for Shenango Coke Works');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (30, 11, 'T', 'F', 'North Yard — Pick up for Neville Island');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (40, 11, 'T', 'F', 'North Yard — Pick up for South Yard');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (50, 11, 'T', 'F', 'North Yard — Pick up for Demmler Yard');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (60, 11, 'F', 'T', 'North Yard — Set out at North Yard');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (70, 2, 'T', 'F', 'West Yard — Pick up for Scully Yard');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (80, 2, 'T', 'F', 'West Yard — Pick up for Shenango Coke Works');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (90, 2, 'T', 'F', 'West Yard — Pick up for Neville Island');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (100, 2, 'T', 'F', 'West Yard — Pick up for South Yard');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (110, 2, 'T', 'F', 'West Yard — Pick up for Demmler Yard');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (120, 2, 'F', 'T', 'West Yard — Set out at West Yard');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (130, 13, 'T', 'F', 'East Yard — Pick up for Scully Yard');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (140, 13, 'T', 'F', 'East Yard — Pick up for Shenango Coke Works');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (150, 13, 'T', 'F', 'East Yard — Pick up for Neville Island');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (160, 13, 'T', 'F', 'East Yard — Pick up for South Yard');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (170, 13, 'T', 'F', 'East Yard — Pick up for Demmler Yard');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (180, 13, 'F', 'T', 'East Yard — Set out at East Yard');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (190, 8, 'T', 'F', 'South Yard — Pick up for Scully Yard');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (200, 8, 'T', 'F', 'South Yard — Pick up for East Yard');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (210, 8, 'T', 'F', 'South Yard — Pick up for Shenango Coke Works');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (220, 8, 'T', 'F', 'South Yard — Pick up for Neville Island');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (230, 8, 'T', 'F', 'South Yard — Pick up for Demmler Yard');
INSERT INTO `YM1` (step_number, station, pickup, setout, remarks) VALUES (240, 8, 'F', 'T', 'South Yard — Set out at South Yard');

DELETE FROM `CK1`;
INSERT INTO `CK1` (step_number, station, pickup, setout, remarks) VALUES (10, 11, 'T', 'T', 'North Yard — Pick up for North Yard; Set out at North Yard');
INSERT INTO `CK1` (step_number, station, pickup, setout, remarks) VALUES (20, 11, 'T', 'F', 'North Yard — Pick up for Scully Yard');
INSERT INTO `CK1` (step_number, station, pickup, setout, remarks) VALUES (30, 11, 'T', 'F', 'North Yard — Pick up for Shenango Coke Works');
INSERT INTO `CK1` (step_number, station, pickup, setout, remarks) VALUES (40, 11, 'T', 'F', 'North Yard — Pick up for South Yard');
INSERT INTO `CK1` (step_number, station, pickup, setout, remarks) VALUES (50, 11, 'T', 'F', 'North Yard — Pick up for Demmler Yard');
INSERT INTO `CK1` (step_number, station, pickup, setout, remarks) VALUES (60, 12, 'T', 'F', 'Shenango Coke Works — Pick up for North Yard');
INSERT INTO `CK1` (step_number, station, pickup, setout, remarks) VALUES (70, 12, 'T', 'F', 'Shenango Coke Works — Pick up for Scully Yard');
INSERT INTO `CK1` (step_number, station, pickup, setout, remarks) VALUES (80, 12, 'T', 'T', 'Shenango Coke Works — Pick up for Shenango Coke Works; Set out at Shenango Coke Works');
INSERT INTO `CK1` (step_number, station, pickup, setout, remarks) VALUES (90, 12, 'T', 'F', 'Shenango Coke Works — Pick up for South Yard');
INSERT INTO `CK1` (step_number, station, pickup, setout, remarks) VALUES (100, 12, 'T', 'F', 'Shenango Coke Works — Pick up for Demmler Yard');
INSERT INTO `CK1` (step_number, station, pickup, setout, remarks) VALUES (110, 8, 'T', 'F', 'South Yard — Pick up for North Yard');
INSERT INTO `CK1` (step_number, station, pickup, setout, remarks) VALUES (120, 8, 'T', 'F', 'South Yard — Pick up for Scully Yard');
INSERT INTO `CK1` (step_number, station, pickup, setout, remarks) VALUES (130, 8, 'T', 'F', 'South Yard — Pick up for Shenango Coke Works');
INSERT INTO `CK1` (step_number, station, pickup, setout, remarks) VALUES (140, 8, 'T', 'F', 'South Yard — Pick up for Demmler Yard');
INSERT INTO `CK1` (step_number, station, pickup, setout, remarks) VALUES (150, 8, 'F', 'T', 'South Yard — Set out at South Yard');

DELETE FROM `STG-SCULLY`;
INSERT INTO `STG-SCULLY` (step_number, station, pickup, setout, remarks) VALUES (10, 9, 'T', 'T', 'Scully Yard — Pick up for Scully Yard; Set out at Scully Yard');
INSERT INTO `STG-SCULLY` (step_number, station, pickup, setout, remarks) VALUES (20, 9, 'T', 'F', 'Scully Yard — Pick up for Shenango Coke Works');
INSERT INTO `STG-SCULLY` (step_number, station, pickup, setout, remarks) VALUES (30, 9, 'T', 'F', 'Scully Yard — Pick up for Neville Island');
INSERT INTO `STG-SCULLY` (step_number, station, pickup, setout, remarks) VALUES (40, 9, 'T', 'F', 'Scully Yard — Pick up for Demmler Yard');

DELETE FROM `STG-DEMMLER`;
INSERT INTO `STG-DEMMLER` (step_number, station, pickup, setout, remarks) VALUES (10, 10, 'T', 'F', 'Demmler Yard — Pick up for Scully Yard');
INSERT INTO `STG-DEMMLER` (step_number, station, pickup, setout, remarks) VALUES (20, 10, 'T', 'F', 'Demmler Yard — Pick up for Shenango Coke Works');
INSERT INTO `STG-DEMMLER` (step_number, station, pickup, setout, remarks) VALUES (30, 10, 'T', 'F', 'Demmler Yard — Pick up for Neville Island');
INSERT INTO `STG-DEMMLER` (step_number, station, pickup, setout, remarks) VALUES (40, 10, 'T', 'T', 'Demmler Yard — Pick up for Demmler Yard; Set out at Demmler Yard');

UPDATE jobs SET description = 'CSX Neville Island Switcher.
Works South Yard and CSX Demmler interchange.
- Demmler Yard: pick up inbound and offline for Scully, Shenango, Neville Island, and Demmler; set out outbound
- South Yard: set out inbound; pick up for Demmler' WHERE name = 'D749';
UPDATE jobs SET description = 'POHC Neville Local.
Works Scully interchange, Neville Island industries, and South Yard.
- Scully Yard: pick up and set out interchange traffic for all destinations
- Neville Island: industry spotting and pulls for Scully, Shenango, island, and Demmler
- South Yard: pick up blocks for Scully and island; set out staging' WHERE name = 'NVL';
UPDATE jobs SET description = 'South Yard yardmaster (YM1) — inter-island switching on Neville Island.
Retrieve and stage cars across North, West, and East satellite yards for island industries.
Sort inbound traffic and build blocks for Scully, Shenango, South Yard, and Demmler (CSX D749).
South Yard staging completes blocks for POHC NVL (via Scully).
D749 and NVL handle interchange and industry spotting; YM1 works satellite yards only.' WHERE name = 'YM1';
UPDATE jobs SET description = 'Coke transfer — optional yard move.
Move coke loads between Shenango Coke Works, North Yard, and South Yard for weighing and classification when authorized and traffic warrants.
One pickup step per destination at each yard.
Run only when it will not interfere with NVL or passenger movements.' WHERE name = 'CK1';
UPDATE jobs SET description = 'Scully Yard staging — offline auto-assign at Scully only.
Pick up interchange traffic for Scully, Shenango, Neville Island, and Demmler.' WHERE name = 'STG-SCULLY';
UPDATE jobs SET description = 'Demmler Yard staging — offline auto-assign at Demmler only.
Pick up interchange traffic for Scully, Shenango, Neville Island, and Demmler.' WHERE name = 'STG-DEMMLER';

INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (1, 'D749', 10, '', NULL, NULL, 10);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (2, 'D749', 30, '', NULL, NULL, 9);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (3, 'D749', 40, '', NULL, NULL, 12);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (4, 'D749', 50, '', NULL, NULL, 3);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (5, 'D749', 60, '', NULL, NULL, 10);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (6, 'NVL', 10, '', NULL, NULL, 9);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (7, 'NVL', 20, '', NULL, NULL, 12);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (8, 'NVL', 30, '', NULL, NULL, 3);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (9, 'NVL', 40, '', NULL, NULL, 10);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (10, 'NVL', 50, '', NULL, NULL, 9);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (11, 'NVL', 60, '', NULL, NULL, 12);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (12, 'NVL', 70, '', NULL, NULL, 3);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (13, 'NVL', 80, '', NULL, NULL, 10);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (14, 'NVL', 90, '', NULL, NULL, 9);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (15, 'NVL', 100, '', NULL, NULL, 3);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (16, 'YM1', 10, '', NULL, NULL, 9);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (17, 'YM1', 20, '', NULL, NULL, 12);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (18, 'YM1', 30, '', NULL, NULL, 3);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (19, 'YM1', 40, '', NULL, NULL, 8);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (20, 'YM1', 50, '', NULL, NULL, 10);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (21, 'YM1', 70, '', NULL, NULL, 9);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (22, 'YM1', 80, '', NULL, NULL, 12);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (23, 'YM1', 90, '', NULL, NULL, 3);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (24, 'YM1', 100, '', NULL, NULL, 8);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (25, 'YM1', 110, '', NULL, NULL, 10);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (26, 'YM1', 130, '', NULL, NULL, 9);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (27, 'YM1', 140, '', NULL, NULL, 12);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (28, 'YM1', 150, '', NULL, NULL, 3);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (29, 'YM1', 160, '', NULL, NULL, 8);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (30, 'YM1', 170, '', NULL, NULL, 10);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (31, 'YM1', 190, '', NULL, NULL, 9);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (32, 'YM1', 200, '', NULL, NULL, 13);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (33, 'YM1', 210, '', NULL, NULL, 12);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (34, 'YM1', 220, '', NULL, NULL, 3);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (35, 'YM1', 230, '', NULL, NULL, 10);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (36, 'CK1', 10, '', NULL, NULL, 11);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (37, 'CK1', 20, '', NULL, NULL, 9);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (38, 'CK1', 30, '', NULL, NULL, 12);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (39, 'CK1', 40, '', NULL, NULL, 8);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (40, 'CK1', 50, '', NULL, NULL, 10);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (41, 'CK1', 60, '', NULL, NULL, 11);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (42, 'CK1', 70, '', NULL, NULL, 9);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (43, 'CK1', 80, '', NULL, NULL, 12);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (44, 'CK1', 90, '', NULL, NULL, 8);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (45, 'CK1', 100, '', NULL, NULL, 10);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (46, 'CK1', 110, '', NULL, NULL, 11);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (47, 'CK1', 120, '', NULL, NULL, 9);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (48, 'CK1', 130, '', NULL, NULL, 12);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (49, 'CK1', 140, '', NULL, NULL, 10);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (50, 'STG-SCULLY', 10, '', NULL, NULL, 9);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (51, 'STG-SCULLY', 20, '', NULL, NULL, 12);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (52, 'STG-SCULLY', 30, '', NULL, NULL, 3);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (53, 'STG-SCULLY', 40, '', NULL, NULL, 10);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (54, 'STG-DEMMLER', 10, '', NULL, NULL, 9);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (55, 'STG-DEMMLER', 20, '', NULL, NULL, 12);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (56, 'STG-DEMMLER', 30, '', NULL, NULL, 3);
INSERT INTO pu_criteria (id, job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES (57, 'STG-DEMMLER', 40, '', NULL, NULL, 10);
