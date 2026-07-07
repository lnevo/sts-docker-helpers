-- Remove COKE-003 direct shipment (EAST-YARD -> DEM-OUT-USS).

DELETE FROM pool
WHERE shipment_id IN (SELECT id FROM shipments WHERE code = 'COKE-003');

DELETE FROM car_orders
WHERE shipment IN (SELECT id FROM shipments WHERE code = 'COKE-003');

DELETE FROM shipments
WHERE code = 'COKE-003';
