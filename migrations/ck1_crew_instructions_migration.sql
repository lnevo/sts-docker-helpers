-- CK1 crew instructions synced from live DB.
UPDATE jobs
SET description = 'Coke Transfer

1. Calibrate track scale using the scale test car.
2. Pick up cars to be reloaded at Shenango Coke Works
1. Set out reloads and pick up outgoing coke cars from shipping tracks.
2. Run to South Yard Scale located on the West Lead of South Yard.
3. Weigh track string via CIM scale at a continuous, steady 4 MPH—keep cars fully stretched and do not apply brakes.
4. Record the actual weight and reassign imbalanced cars to RELOAD car orders.
4. Set out all cars in South Yard to be classified.

Refer to HART Railroad Scale Operating Instructions for calibration and usage details.'
WHERE name = 'CK1';
