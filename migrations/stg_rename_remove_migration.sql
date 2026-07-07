-- Remove STG3; rename STG1/STG2 to STG-SCULLY / STG-DEMMLER.

UPDATE cars SET handled_by_job_id = 0 WHERE handled_by_job_id = 7;
DELETE FROM pu_criteria WHERE job_id = 'STG3';
UPDATE pu_criteria SET job_id = 'STG-SCULLY' WHERE job_id = 'STG1';
UPDATE pu_criteria SET job_id = 'STG-DEMMLER' WHERE job_id = 'STG2';
RENAME TABLE STG1 TO `STG-SCULLY`;
RENAME TABLE STG2 TO `STG-DEMMLER`;
DROP TABLE IF EXISTS STG3;
DELETE FROM jobs WHERE name = 'STG3';
UPDATE jobs SET name = 'STG-SCULLY', description = 'Scully Yard staging — offline auto-assign at Scully only.
Pick up interchange traffic for Scully, Shenango, Neville Island, and Demmler.' WHERE id = 5;
UPDATE jobs SET name = 'STG-DEMMLER', description = 'Demmler Yard staging — offline auto-assign at Demmler only.
Pick up interchange traffic for Scully, Shenango, Neville Island, and Demmler.' WHERE id = 6;
