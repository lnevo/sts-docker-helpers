-- Staging step 100: enable setout at North Yard.

UPDATE Staging
SET setout = 'T'
WHERE step_number = 100;
