-- Satellite yard location renames and East Yard restoration.

UPDATE locations SET code = 'SOUTH-SCALE' WHERE code = 'SOUTH-YARD-SCALE';
UPDATE locations SET code = 'SOUTH' WHERE code = 'SOUTH-YARD';
UPDATE locations SET code = 'NORTH' WHERE code = 'NORTH-YARD';
UPDATE locations SET code = 'WEST' WHERE code = 'WEST-YARD';

INSERT INTO locations (Id, code, station, track, spot, rpt_station, remarks, color)
SELECT IFNULL(MAX(Id), 0) + 1, 'EAST', 13, '', '', '', '', ''
FROM locations
WHERE NOT EXISTS (SELECT 1 FROM locations WHERE code = 'EAST');

INSERT INTO routing (id, station, station_nbr, instructions, sort_seq, color1, color2)
SELECT
  13,
  'East Yard',
  (SELECT Id FROM locations WHERE code = 'EAST' LIMIT 1),
  'Reserved for future staging.',
  275,
  0,
  0
WHERE NOT EXISTS (SELECT 1 FROM routing WHERE id = 13);

UPDATE routing
SET station = 'East Yard',
    station_nbr = (SELECT Id FROM locations WHERE code = 'EAST' LIMIT 1),
    instructions = 'Reserved for future staging.',
    sort_seq = 275
WHERE id = 13;
