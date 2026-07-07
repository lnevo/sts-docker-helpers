-- Remove inbound yard block locations; home yards SCL/DEM handle all yard car handling.

UPDATE cars c
JOIN locations bl ON c.current_location_id = bl.id
JOIN locations scl ON scl.code = 'SCL'
SET c.current_location_id = scl.id
WHERE bl.code IN ('SCL-RCV', 'SCL-IN');

UPDATE cars c
JOIN locations bl ON c.current_location_id = bl.id
JOIN locations dem ON dem.code = 'DEM'
SET c.current_location_id = dem.id
WHERE bl.code IN ('DEM-RCV', 'DEM-IN');

DELETE FROM locations WHERE code IN ('SCL-RCV', 'DEM-RCV', 'SCL-IN', 'DEM-IN');

UPDATE locations SET color = 'pink' WHERE code = 'SCL';
UPDATE locations SET color = 'purple' WHERE code = 'DEM';
