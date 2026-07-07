-- Remove COKE-SCALE shipment (EAST-YARD -> SOUTH-YARD-SCALE).

DELETE FROM pool
WHERE shipment_id IN (SELECT id FROM shipments WHERE code = 'COKE-SCALE');

DELETE FROM car_orders
WHERE shipment IN (SELECT id FROM shipments WHERE code = 'COKE-SCALE');

DELETE FROM shipments
WHERE code = 'COKE-SCALE';
