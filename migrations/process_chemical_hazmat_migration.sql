-- Process Chemicals commodity hazmat remarks (UN/class/placard + handling).
UPDATE commodities SET remarks = 'HAZMAT: Class 2.2 Non-flammable gas; UN1006; Placard Non-Flammable Gas; 1 spacer from loco/caboose/passenger' WHERE code = 'ARGON';
UPDATE commodities SET remarks = 'HAZMAT: Class 8 Corrosive; UN1824; Placard Corrosive; Do not place adjacent to food or reefers' WHERE code = 'CAUSTICSODA';
UPDATE commodities SET remarks = 'HAZMAT: Class 3 Flammable liquid; UN1919; Placard Flammable; Do not hump; 1 spacer from loco/caboose/passenger' WHERE code = 'ETHYLACRYLATE';
UPDATE commodities SET remarks = 'HAZMAT: Class 8 Corrosive; UN1789; Placard Corrosive; Do not place adjacent to food or reefers' WHERE code = 'HYDROCHLORICACID';
UPDATE commodities SET remarks = 'HAZMAT: Class 2.2 Non-flammable gas; UN2187; Placard Non-Flammable Gas; 1 spacer from loco/caboose/passenger' WHERE code = 'INDUSTRIALGASES';
UPDATE commodities SET remarks = 'HAZMAT: Class 3 Flammable liquid; UN1247; Placard Flammable; Do not hump; 1 spacer from loco/caboose/passenger' WHERE code = 'METHYLMETHACRYLATE';
UPDATE commodities SET remarks = 'HAZMAT: Class 4.1 Flammable solid; UN1381; Placard Flammable Solid; Do not hump; 2 spacers from occupied equipment' WHERE code = 'PHOSPHORCOMPOUNDS';
UPDATE commodities SET remarks = 'HAZMAT: Class 8 Corrosive; UN1805; Placard Corrosive; Do not place adjacent to food or reefers' WHERE code = 'PHOSPHORICACID';
UPDATE commodities SET remarks = 'HAZMAT: See specific chemical commodity code for UN/placard and handling restrictions' WHERE code = 'PROCCHEM';
UPDATE commodities SET remarks = 'HAZMAT: Class 3 Flammable liquid; UN2054; Placard Flammable; Do not hump; 1 spacer from loco/caboose/passenger' WHERE code = 'STYRENEMONOMER';
