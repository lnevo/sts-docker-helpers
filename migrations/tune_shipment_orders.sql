-- HART shipment tuning — target ~20-24 car orders on first Generate Session.
--
-- Amounts: IX + local industries fire 1 car at a time (more lane variety under
-- max_new). Aristech may take 1–2. Coke bulk amounts set below.
-- Tiered intervals (apply in order — later statements override earlier ones):
--   Local industry (general)    interval 0-2, amount 1-1
--   Local gravity covered hopper (HC) interval 2-5
--   Local gondola (GA/GD)       interval 3-5
--   Local flatcar (FM)          interval 0-2, amount 1-1
--   Local covered hopper (HP)   interval 2-4  (2 HP cars)
--   Local tank (TA/TL)          interval 1-2
--   Interchange (general)       interval 0-2, amount 1-1
--   Interchange gravity covered hopper (HC) interval 3-6
--   Interchange flatcar (FM)    interval 0-2, amount 1-1
--   Interchange covered hopper (HP) interval 4-7
--   Interchange tank (TA/TL)    interval 2-4
--   Interchange gondola (GA/GD) interval 5-8
--   Aristech (all codes)        amount 1-2 (after tier updates)

-- Local industry — general car types
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = 0,
    s.max_interval = 2,
    s.min_amount = 1,
    s.max_amount = 1
WHERE s.code NOT LIKE 'IX-%'
  AND s.code NOT LIKE 'COKE-%'
  AND cc.code NOT IN ('GA', 'GD', 'FM', 'HP', 'HC', 'TA', 'TL', 'HM', 'HK', 'HT', 'H*');

-- Local industry — gravity covered hopper (HC)
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = 2,
    s.max_interval = 5,
    s.min_amount = 1,
    s.max_amount = 1
WHERE s.code NOT LIKE 'IX-%'
  AND s.code NOT LIKE 'COKE-%'
  AND cc.code = 'HC';

-- Local industry — gondola (GA/GD)
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = 3,
    s.max_interval = 5,
    s.min_amount = 1,
    s.max_amount = 1
WHERE s.code NOT LIKE 'IX-%'
  AND s.code NOT LIKE 'COKE-%'
  AND cc.code IN ('GA', 'GD');

-- Local industry — flatcar (FM)
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = 0,
    s.max_interval = 2,
    s.min_amount = 1,
    s.max_amount = 1
WHERE s.code NOT LIKE 'IX-%'
  AND s.code NOT LIKE 'COKE-%'
  AND cc.code = 'FM';

-- Local industry — pneumatic covered hopper (HP)
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = 2,
    s.max_interval = 4,
    s.min_amount = 1,
    s.max_amount = 1
WHERE s.code NOT LIKE 'IX-%'
  AND s.code NOT LIKE 'COKE-%'
  AND cc.code = 'HP';

-- Local industry — tank (TA/TL)
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = 1,
    s.max_interval = 2,
    s.min_amount = 1,
    s.max_amount = 1
WHERE s.code NOT LIKE 'IX-%'
  AND s.code NOT LIKE 'COKE-%'
  AND cc.code IN ('TA', 'TL');

-- Coke outbound singles — manual only, one car each when selected
UPDATE shipments
SET min_interval = 99,
    max_interval = 99,
    min_amount = 1,
    max_amount = 1
WHERE code IN ('COKE-USS', 'COKE-CLEV');

-- Coke outbound bulk — both lanes each cycle; 3 cars (83.6 confirming stack)
UPDATE shipments
SET min_interval = 2,
    max_interval = 2,
    min_amount = 3,
    max_amount = 3
WHERE code IN ('COKE-USS-BULK', 'COKE-CLEV-BULK');

-- Coke reload — manual only (one car when selected)
UPDATE shipments
SET min_interval = 99,
    max_interval = 99,
    min_amount = 1,
    max_amount = 1
WHERE code IN ('COKE-RELOAD-SHEN', 'COKE-RELOAD-NORTH');

-- Interchange — general car types
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = 0,
    s.max_interval = 2,
    s.min_amount = 1,
    s.max_amount = 1
WHERE s.code LIKE 'IX-%'
  AND cc.code NOT IN ('TA', 'TL', 'GA', 'GD', 'FM', 'HP', 'HC', 'HM', 'HK', 'HT', 'H*');

-- Interchange — gravity covered hopper (HC)
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = 3,
    s.max_interval = 6,
    s.min_amount = 1,
    s.max_amount = 1
WHERE s.code LIKE 'IX-%'
  AND cc.code = 'HC';

-- Interchange — flatcar (FM)
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = 0,
    s.max_interval = 2,
    s.min_amount = 1,
    s.max_amount = 1
WHERE s.code LIKE 'IX-%'
  AND cc.code = 'FM';

-- Interchange — pneumatic covered hopper (HP)
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = 4,
    s.max_interval = 7,
    s.min_amount = 1,
    s.max_amount = 1
WHERE s.code LIKE 'IX-%'
  AND cc.code = 'HP';

-- Interchange — tank (TA/TL)
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = 2,
    s.max_interval = 4,
    s.min_amount = 1,
    s.max_amount = 1
WHERE s.code LIKE 'IX-%'
  AND cc.code IN ('TA', 'TL');

-- Interchange — gondola (GA/GD)
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = 5,
    s.max_interval = 8,
    s.min_amount = 1,
    s.max_amount = 1
WHERE s.code LIKE 'IX-%'
  AND cc.code IN ('GA', 'GD');

-- Aristech exception — allow 1 or 2 cars per generate (after tier caps).
UPDATE shipments
SET min_amount = 1,
    max_amount = 2
WHERE code LIKE 'ARIS-%';
