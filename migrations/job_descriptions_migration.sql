-- Restore summary job descriptions (steps unchanged).

UPDATE jobs SET description = 'CSX Neville Island Switcher.
Works South Yard and CSX Demmler interchange.
- Demmler Yard: pick up inbound and offline for Scully, Shenango, Neville Island, and Demmler; set out outbound
- South Yard: set out inbound; pick up for Demmler' WHERE name = 'D749';
UPDATE jobs SET description = 'POHC Neville Local.
Works Scully interchange, Neville Island industries, and South Yard.
- Scully Yard: pick up and set out interchange traffic for all destinations
- Neville Island: industry spotting and pulls for Scully, Shenango, island, and Demmler
- South Yard: pick up blocks for Scully and island; set out staging' WHERE name = 'NVL';
UPDATE jobs SET description = 'South Yard yardmaster (YM1) — inter-island switching on Neville Island.
Retrieve and stage cars across North, West, and East satellite yards for island industries.
Sort inbound traffic and build blocks for Scully, Shenango, South Yard, and Demmler (CSX D749).
South Yard staging completes blocks for POHC NVL (via Scully).
D749 and NVL handle interchange and industry spotting; YM1 works satellite yards only.' WHERE name = 'YM1';
UPDATE jobs SET description = 'Coke transfer — optional yard move.
Move coke loads between Shenango Coke Works, North Yard, and South Yard for weighing and classification when authorized and traffic warrants.
One pickup step per destination at each yard.
Run only when it will not interfere with NVL or passenger movements.' WHERE name = 'CK1';
UPDATE jobs SET description = 'Scully Yard staging — offline auto-assign at Scully only.
Pick up interchange traffic for Scully, Shenango, Neville Island, and Demmler.' WHERE name = 'STG1';
UPDATE jobs SET description = 'Demmler Yard staging — offline auto-assign at Demmler only.
Pick up interchange traffic for Scully, Shenango, Neville Island, and Demmler.' WHERE name = 'STG2';
UPDATE jobs SET description = 'Shenango Coke Works staging — coke export and North Yard reloads for Shenango.
- North Yard: pick up pending loads for Shenango, Scully, South Yard scale, and Demmler
- Shenango: pick up export coke for Scully, South Yard, and Demmler; set out' WHERE name = 'STG3';
