-- Hotter Neville Island local intervals (amounts unchanged by this file).
-- Prefer apply_island_heat.php for named cases; this SQL is the isl_hot profile.

UPDATE shipments
SET min_interval = 0,
    max_interval = 1
WHERE (
    code LIKE 'ARIS-%'
    OR code LIKE 'STUK-%'
    OR code LIKE 'CALG-%'
    OR code LIKE 'FERR-%'
    OR code LIKE 'KOSM-%'
  )
  AND code NOT LIKE 'COKE-%';

-- Ferrel: eligible every session when due.
UPDATE shipments
SET min_interval = 0,
    max_interval = 0
WHERE code LIKE 'FERR-%';
