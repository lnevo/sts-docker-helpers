-- Remove YM1 yardmaster job entirely

UPDATE cars SET handled_by_job_id = 0 WHERE handled_by_job_id = 3;
DELETE FROM pu_criteria WHERE job_id = 'YM1';
DELETE FROM jobs WHERE id = 3 OR name = 'YM1';
DROP TABLE IF EXISTS `YM1`;

UPDATE routing SET instructions = 'Outbound coke staging — CK1 to South Yard when authorized.
Cars for island industries or South Yard classification.'
WHERE id = 11;

UPDATE routing SET instructions = 'Satellite staging yard for Neville Island traffic.'
WHERE id = 2;
