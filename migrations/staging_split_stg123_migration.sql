-- Split Staging into STG1 (Scully), STG2 (Demmler), STG3 (Shenango + North Yard).

DELETE FROM pu_criteria WHERE job_id = 'Staging';
DELETE FROM jobs WHERE name = 'Staging';
DROP TABLE IF EXISTS Staging;

INSERT INTO jobs (id, name, description) VALUES
(5, 'STG1', 'Scully Yard staging — pick up interchange and island traffic at Scully only.
- Scully Yard: pick up for Scully, Neville Island, and Demmler'),
(6, 'STG2', 'Demmler Yard staging — pick up interchange and island traffic at Demmler only.
- Demmler Yard: pick up for Demmler, Neville Island, and Scully'),
(7, 'STG3', 'Shenango Coke Works staging — coke export and North Yard reloads for Shenango.
- Shenango: pick up loaded coke for Demmler export, Scully export, and South Yard scale
- North Yard: pick up pending loads for Shenango');

CREATE TABLE IF NOT EXISTS STG1 (
  step_number int(11) NOT NULL,
  station int(11) NOT NULL,
  pickup varchar(1) NOT NULL,
  setout varchar(1) NOT NULL,
  remarks text
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

CREATE TABLE IF NOT EXISTS STG2 (
  step_number int(11) NOT NULL,
  station int(11) NOT NULL,
  pickup varchar(1) NOT NULL,
  setout varchar(1) NOT NULL,
  remarks text
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

CREATE TABLE IF NOT EXISTS STG3 (
  step_number int(11) NOT NULL,
  station int(11) NOT NULL,
  pickup varchar(1) NOT NULL,
  setout varchar(1) NOT NULL,
  remarks text
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

DELETE FROM STG1;
INSERT INTO STG1 (step_number, station, pickup, setout, remarks) VALUES
(10, 9, 'T', 'T', 'Scully Yard — pick up for Scully Yard'),
(20, 9, 'T', 'T', 'Scully Yard — pick up for Neville Island'),
(30, 9, 'T', 'T', 'Scully Yard — pick up for Demmler Yard');

DELETE FROM STG2;
INSERT INTO STG2 (step_number, station, pickup, setout, remarks) VALUES
(10, 10, 'T', 'T', 'Demmler Yard — pick up for Demmler Yard'),
(20, 10, 'T', 'T', 'Demmler Yard — pick up for Neville Island'),
(30, 10, 'T', 'T', 'Demmler Yard — pick up for Scully Yard');

DELETE FROM STG3;
INSERT INTO STG3 (step_number, station, pickup, setout, remarks) VALUES
(10, 12, 'T', 'T', 'Shenango Coke Works — pick up coke for Demmler Yard export'),
(20, 12, 'T', 'T', 'Shenango Coke Works — pick up coke for Scully Yard export'),
(30, 12, 'T', 'T', 'Shenango Coke Works — pick up coke for South Yard scale'),
(40, 11, 'T', 'T', 'North Yard — pick up pending loads for Shenango Coke Works');

INSERT INTO pu_criteria (job_id, step_nbr, car_status, commodity_id, car_code_id, dest_station_id) VALUES
('STG1', 10, '', NULL, NULL, 9),
('STG1', 20, '', NULL, NULL, 3),
('STG1', 30, '', NULL, NULL, 10),
('STG2', 10, '', NULL, NULL, 10),
('STG2', 20, '', NULL, NULL, 3),
('STG2', 30, '', NULL, NULL, 9),
('STG3', 10, 'Loaded', NULL, NULL, 10),
('STG3', 20, 'Loaded', NULL, NULL, 9),
('STG3', 30, 'Loaded', NULL, NULL, 8),
('STG3', 40, 'Ordered', NULL, NULL, 12);
