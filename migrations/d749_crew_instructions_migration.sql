-- D749 crew instructions: Neville Island to McKeesport turn.
UPDATE jobs
SET description = 'Turn from Neville Island to McKeesport.

Departure Instructions:
1. Retrieve power from engine terminal. Top off fuel and sand.
2. Pickup train from West Yard with consist from previous shift.
3. Interchange cars at South Yard following yardmaster instructions.
4. Depart Neville Island. Wait for dispatcher clearance to cross the bridge.

Arrival Instructions:
1. Return from McKeesport with inbound cars.
2. Follow yardmaster instructions for arrival in West Yard or South Yard.
3. Park engine in terminal.'
WHERE name = 'D749';
