-- Expand coke HM pool by 5 cars; reclassify NW12986 HC -> HM.
-- New pool cars: NW12986, NW12988, BO30222, BO30963, BO31000 (×5 coke shipments each).

UPDATE cars
SET car_code_id = (SELECT id FROM car_codes WHERE code = 'HM' LIMIT 1)
WHERE reporting_marks = 'NW12986';

INSERT INTO pool (car_id, shipment_id)
SELECT c.id, s.id
FROM cars c
CROSS JOIN shipments s
WHERE c.reporting_marks IN ('NW12986', 'NW12988', 'BO30222', 'BO30963', 'BO31000')
  AND s.code IN (
    'COKE-USS', 'COKE-CLEV', 'COKE-USS-BULK', 'COKE-CLEV-BULK', 'COKE-RELOAD-EAST'
  )
  AND NOT EXISTS (
    SELECT 1 FROM pool p WHERE p.car_id = c.id AND p.shipment_id = s.id
  );
