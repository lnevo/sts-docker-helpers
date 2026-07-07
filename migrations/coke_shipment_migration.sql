-- Coke shipment refactor: staging locations, COKE-001/002 fixes, COKE-003 direct route.
-- Safe to re-run (idempotent inserts/updates).

INSERT INTO locations (code, station, track, spot, rpt_station, remarks, color)
SELECT 'SCL-OUT', 9, 'OUTBOUND', 'OUT', 'Scully Yard', '', ''
WHERE NOT EXISTS (SELECT 1 FROM locations WHERE code = 'SCL-OUT');

INSERT INTO locations (code, station, track, spot, rpt_station, remarks, color)
SELECT 'SCL-OUT-CLEV', 9, 'OFFLINE', 'OUT', 'OUT — NS / POHC interchange', 'POHC', ''
WHERE NOT EXISTS (SELECT 1 FROM locations WHERE code = 'SCL-OUT-CLEV');

INSERT INTO locations (code, station, track, spot, rpt_station, remarks, color)
SELECT 'DEM-OUT', 10, 'OUTBOUND', 'OUT', 'Demmler Yard', '', ''
WHERE NOT EXISTS (SELECT 1 FROM locations WHERE code = 'DEM-OUT');

INSERT INTO locations (code, station, track, spot, rpt_station, remarks, color)
SELECT 'DEM-OUT-USS', 10, 'OFFLINE', 'OUT', 'OUT — U.S. Steel Edgar Thomson Works', 'CSX', ''
WHERE NOT EXISTS (SELECT 1 FROM locations WHERE code = 'DEM-OUT-USS');

UPDATE shipments s
INNER JOIN locations ll ON ll.code = 'SOUTH-YARD-SCALE'
INNER JOIN locations ul ON ul.code = 'DEM-OUT-USS'
SET s.description = 'Shenango Coke Works to U.S. Steel Edgar Thomson Works',
    s.loading_location = ll.id,
    s.unloading_location = ul.id,
    s.special_instructions = 'CSX | URR'
WHERE s.code = 'COKE-001';

UPDATE shipments s
INNER JOIN locations ll ON ll.code = 'SOUTH-YARD-SCALE'
INNER JOIN locations ul ON ul.code = 'SCL-OUT-CLEV'
SET s.description = 'Shenango Coke Works to Cleveland Works, Cleveland, OH',
    s.loading_location = ll.id,
    s.unloading_location = ul.id,
    s.special_instructions = 'POHC | NS via McKees Rocks'
WHERE s.code = 'COKE-002';

INSERT INTO shipments (
    code, description, consignment, car_code, loading_location, unloading_location,
    last_ship_date, min_interval, max_interval, min_amount, max_amount,
    special_instructions, remarks
)
SELECT
    'COKE-003',
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
    'CSX | URR | Direct',
    ''
FROM commodities c
CROSS JOIN car_codes cc
INNER JOIN locations ll ON ll.code = 'EAST-YARD'
INNER JOIN locations ul ON ul.code = 'DEM-OUT-USS'
WHERE c.code = 'COKE'
  AND cc.code = 'H*'
  AND NOT EXISTS (SELECT 1 FROM shipments WHERE code = 'COKE-003');

INSERT INTO pool (car_id, shipment_id)
SELECT DISTINCT p.car_id, s_new.id
FROM pool p
INNER JOIN shipments s_old ON s_old.id = p.shipment_id AND s_old.code = 'COKE-001'
INNER JOIN shipments s_new ON s_new.code = 'COKE-003'
WHERE NOT EXISTS (
    SELECT 1 FROM pool p2
    WHERE p2.car_id = p.car_id AND p2.shipment_id = s_new.id
);

UPDATE shipments
SET min_interval = 99,
    max_interval = 99,
    min_amount = 5,
    max_amount = 5
WHERE code IN ('COKE-001', 'COKE-002', 'COKE-003');
