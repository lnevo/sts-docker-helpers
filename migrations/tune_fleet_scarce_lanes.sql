-- Fleet-balanced lane tune (post traffic_mult crush).
-- Pair with seed: more HP (pellet) cars, two revived HM coke cars, coke bulk 2-3.
-- Does NOT reset last_ship_date. Leaves XM/FM/FC general traffic alone.

-- Local pneumatic covered hopper (HP) — pellets
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = GREATEST(s.min_interval, 2),
    s.max_interval = GREATEST(s.max_interval, 4)
WHERE s.code NOT LIKE 'IX-%'
  AND s.code NOT LIKE 'COKE-%'
  AND cc.code = 'HP';

-- Interchange HP
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = GREATEST(s.min_interval, 4),
    s.max_interval = GREATEST(s.max_interval, 7)
WHERE s.code LIKE 'IX-%'
  AND cc.code = 'HP';

-- Local gravity covered hopper (HC) — cement/carbon/agg
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = GREATEST(s.min_interval, 2),
    s.max_interval = GREATEST(s.max_interval, 5)
WHERE s.code NOT LIKE 'IX-%'
  AND s.code NOT LIKE 'COKE-%'
  AND cc.code = 'HC';

-- Interchange HC
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = GREATEST(s.min_interval, 3),
    s.max_interval = GREATEST(s.max_interval, 6)
WHERE s.code LIKE 'IX-%'
  AND cc.code = 'HC';

-- Local gondola (GA/GD) — 2-car pool
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = GREATEST(s.min_interval, 6),
    s.max_interval = GREATEST(s.max_interval, 10)
WHERE s.code NOT LIKE 'IX-%'
  AND s.code NOT LIKE 'COKE-%'
  AND cc.code IN ('GA', 'GD');

-- Interchange gondola
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = GREATEST(s.min_interval, 8),
    s.max_interval = GREATEST(s.max_interval, 12)
WHERE s.code LIKE 'IX-%'
  AND cc.code IN ('GA', 'GD');

-- Local coal open hoppers (HK/HT)
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = GREATEST(s.min_interval, 4),
    s.max_interval = GREATEST(s.max_interval, 7)
WHERE s.code NOT LIKE 'IX-%'
  AND s.code NOT LIKE 'COKE-%'
  AND cc.code IN ('HK', 'HT');

-- Interchange coal
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = GREATEST(s.min_interval, 4),
    s.max_interval = GREATEST(s.max_interval, 8)
WHERE s.code LIKE 'IX-%'
  AND cc.code IN ('HK', 'HT');

-- Local tank (TA/TL)
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = GREATEST(s.min_interval, 2),
    s.max_interval = GREATEST(s.max_interval, 3)
WHERE s.code NOT LIKE 'IX-%'
  AND s.code NOT LIKE 'COKE-%'
  AND cc.code IN ('TA', 'TL');

-- Interchange tank
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = GREATEST(s.min_interval, 3),
    s.max_interval = GREATEST(s.max_interval, 6)
WHERE s.code LIKE 'IX-%'
  AND cc.code IN ('TA', 'TL');

-- Reefers
UPDATE shipments s
INNER JOIN car_codes cc ON cc.id = s.car_code
SET s.min_interval = GREATEST(s.min_interval, 4),
    s.max_interval = GREATEST(s.max_interval, 7)
WHERE s.code NOT LIKE 'COKE-%'
  AND cc.code = 'RM';

-- Coke bulk — both lanes each session, 2–3 cars (parked long-run stack with gate50 + drain)
UPDATE shipments
SET min_interval = 2,
    max_interval = 2,
    min_amount = 2,
    max_amount = 3
WHERE code IN ('COKE-USS-BULK', 'COKE-CLEV-BULK');

-- Keep singles / reload manual-only
UPDATE shipments
SET min_interval = 99,
    max_interval = 99,
    min_amount = 1,
    max_amount = 1
WHERE code IN ('COKE-USS', 'COKE-CLEV', 'COKE-RELOAD-SHEN');
