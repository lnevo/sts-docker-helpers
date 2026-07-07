-- Assign all cars to club owner Lee Nevo (id 1).

INSERT INTO owners (id, name, remarks)
SELECT 1, 'Lee Nevo', ''
WHERE NOT EXISTS (SELECT 1 FROM owners WHERE id = 1);

UPDATE ownership
SET owner_id = 1
WHERE owner_id IS NULL OR owner_id = 0;

-- Ensure every car has an ownership row.
INSERT INTO ownership (car_id, owner_id, on_off_rr)
SELECT c.id, 1, IF(c.status = 'Unavailable', 'Unavailable', 'on')
FROM cars c
WHERE NOT EXISTS (SELECT 1 FROM ownership o WHERE o.car_id = c.id);
