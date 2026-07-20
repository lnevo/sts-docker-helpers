-- Cap non-coke shipment generate amounts to one car at a time.
-- Aristech may still generate 1–2. Coke bulk lanes are left alone.
-- Intervals are not changed here — only min_amount / max_amount.

-- Default: every non-coke lane fires a single car when eligible.
UPDATE shipments
SET min_amount = 1,
    max_amount = 1
WHERE code NOT LIKE 'COKE-%';

-- Aristech exception: allow 1 or 2 cars per generate.
UPDATE shipments
SET min_amount = 1,
    max_amount = 2
WHERE code LIKE 'ARIS-%';
