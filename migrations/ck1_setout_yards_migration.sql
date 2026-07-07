-- CK1: enable setout at all East Yard and South Yard steps.

UPDATE CK1 SET setout = 'T' WHERE station IN (8, 12);
