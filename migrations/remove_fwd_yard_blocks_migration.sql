-- Remove physical outbound yard blocks; home yards SCL/DEM inherit their colors.

UPDATE cars c
JOIN locations fl ON c.current_location_id = fl.id
JOIN locations scl ON scl.code = 'SCL'
SET c.current_location_id = scl.id
WHERE fl.code IN ('SCL-FWD', 'SCL-OUT');

UPDATE cars c
JOIN locations fl ON c.current_location_id = fl.id
JOIN locations dem ON dem.code = 'DEM'
SET c.current_location_id = dem.id
WHERE fl.code IN ('DEM-FWD', 'DEM-OUT');

DELETE FROM locations WHERE code IN ('SCL-FWD', 'DEM-FWD', 'SCL-OUT', 'DEM-OUT');

UPDATE locations SET color = 'pink' WHERE code = 'SCL';
UPDATE locations SET color = 'purple' WHERE code = 'DEM';
