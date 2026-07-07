-- SCL/DEM home yard renames only (no separate yard block locations).

UPDATE locations SET code = 'SCL', color = 'pink' WHERE code IN ('SCL-YARD', 'SCL-IN', 'SCL-RCV');
UPDATE locations SET code = 'DEM', color = 'purple' WHERE code IN ('DEM-YARD', 'DEM-IN', 'DEM-RCV');
