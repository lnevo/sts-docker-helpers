-- Outbound coke loads from East Yard; rename bulk shipment codes to -BULK.

UPDATE shipments SET code = 'COKE-USS-BULK' WHERE code = 'COKE-USS-Bulk';
UPDATE shipments SET code = 'COKE-CLEV-BULK' WHERE code = 'COKE-CLEV-Bulk';

UPDATE shipments s
INNER JOIN locations l ON l.code = 'EAST-YARD'
SET s.loading_location = l.id
WHERE s.code IN ('COKE-USS', 'COKE-CLEV', 'COKE-USS-BULK', 'COKE-CLEV-BULK');
