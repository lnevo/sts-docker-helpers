-- CK1: setout at Shenango Coke Works (step 60).

DELETE FROM CK1 WHERE step_number = 60;
INSERT INTO CK1 (step_number, station, pickup, setout, remarks) VALUES
(60, 12, 'F', 'T', 'Set out coke loads at Shenango Coke Works');

UPDATE jobs
SET description = 'Coke transfer — optional yard move.
Move coke loads between Shenango Coke Works, North Yard, and South Yard for weighing and classification when authorized and traffic warrants.
Pick up Demmler- and Scully-bound coke at North Yard on separate steps (same pattern as YM1).
Pick up North Yard-bound reloads at South Yard before setout.
Run only when it will not interfere with NVL or passenger movements.'
WHERE name = 'CK1';
