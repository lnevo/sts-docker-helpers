-- Job crew instructions synced from live DB (NVL, STG-SCULLY, STG-DEMMLER).
UPDATE jobs
SET description = 'POHC Neville Island Local

Deliver inbound cars and interchange with CSX


DURING SESSION:
1. After D749 clears the bridge, run to South Yard with dispatcher clearance.
2. Interchange cars at South Yard following yardmaster instructions.
3. Work the local Neville Island industries and Shenango Coke Works.
4. Return to South Yard; Perform final interchange following yardmaster instructions.
5. Depart Neville Island. Wait for dispatcher clearance to cross the bridge.'
WHERE name = 'NVL';

UPDATE jobs
SET description = 'Scully Yard staging 

Swap cars between offline staging and online staging.'
WHERE name = 'STG-SCULLY';

UPDATE jobs
SET description = 'Demmler Yard staging 

Swap cars between offline staging and online staging.'
WHERE name = 'STG-DEMMLER';
