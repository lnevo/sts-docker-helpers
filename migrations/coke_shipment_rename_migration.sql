-- Remove weigh shipments; rename COKE-001/002; add bulk variants.

DELETE FROM pool
WHERE shipment_id IN (SELECT id FROM shipments WHERE code IN ('COKE-WEIGH-001', 'COKE-WEIGH-002'));

DELETE FROM car_orders
WHERE shipment IN (SELECT id FROM shipments WHERE code IN ('COKE-WEIGH-001', 'COKE-WEIGH-002'));

DELETE FROM shipments WHERE code IN ('COKE-WEIGH-001', 'COKE-WEIGH-002');

UPDATE shipments
SET code = 'COKE-USS',
    min_amount = 1,
    max_amount = 1,
    min_interval = 99,
    max_interval = 99
WHERE code = 'COKE-001';

UPDATE shipments
SET code = 'COKE-CLEV',
    min_amount = 1,
    max_amount = 1,
    min_interval = 99,
    max_interval = 99
WHERE code = 'COKE-002';

INSERT INTO shipments (
    code, description, consignment, car_code, loading_location, unloading_location,
    last_ship_date, min_interval, max_interval, min_amount, max_amount,
    special_instructions, remarks
)
SELECT
    'COKE-USS-Bulk',
    'Shenango Coke Works to U.S. Steel Edgar Thomson Works',
    c.id,
    cc.id,
    ll.id,
    ul.id,
    0,
    99,
    99,
    5,
    5,
    'CSX | URR',
    ''
FROM commodities c
CROSS JOIN car_codes cc
INNER JOIN locations ll ON ll.code = 'SOUTH-YARD-SCALE'
INNER JOIN locations ul ON ul.code = 'DEM-OUT-USS'
WHERE c.code = 'COKE'
  AND cc.code = 'H*'
  AND NOT EXISTS (SELECT 1 FROM shipments WHERE code = 'COKE-USS-Bulk');

INSERT INTO shipments (
    code, description, consignment, car_code, loading_location, unloading_location,
    last_ship_date, min_interval, max_interval, min_amount, max_amount,
    special_instructions, remarks
)
SELECT
    'COKE-CLEV-Bulk',
    'Shenango Coke Works to Cleveland Works, Cleveland, OH',
    c.id,
    cc.id,
    ll.id,
    ul.id,
    0,
    99,
    99,
    5,
    5,
    'POHC | NS via McKees Rocks',
    ''
FROM commodities c
CROSS JOIN car_codes cc
INNER JOIN locations ll ON ll.code = 'SOUTH-YARD-SCALE'
INNER JOIN locations ul ON ul.code = 'SCL-OUT-CLEV'
WHERE c.code = 'COKE'
  AND cc.code = 'H*'
  AND NOT EXISTS (SELECT 1 FROM shipments WHERE code = 'COKE-CLEV-Bulk');

INSERT INTO pool (car_id, shipment_id)
SELECT DISTINCT p.car_id, s_new.id
FROM pool p
INNER JOIN shipments s_old ON s_old.id = p.shipment_id AND s_old.code = 'COKE-USS'
INNER JOIN shipments s_new ON s_new.code = 'COKE-USS-Bulk'
WHERE NOT EXISTS (
    SELECT 1 FROM pool p2
    WHERE p2.car_id = p.car_id AND p2.shipment_id = s_new.id
);

INSERT INTO pool (car_id, shipment_id)
SELECT DISTINCT p.car_id, s_new.id
FROM pool p
INNER JOIN shipments s_old ON s_old.id = p.shipment_id AND s_old.code = 'COKE-CLEV'
INNER JOIN shipments s_new ON s_new.code = 'COKE-CLEV-Bulk'
WHERE NOT EXISTS (
    SELECT 1 FROM pool p2
    WHERE p2.car_id = p.car_id AND p2.shipment_id = s_new.id
);
