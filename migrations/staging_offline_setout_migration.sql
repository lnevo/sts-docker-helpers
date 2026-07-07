-- Enable setout at offline stations on staging home-offline step 12

UPDATE `STG-SCULLY` SET pickup = 'T', setout = 'T',
  remarks = 'Scully Offline — Pick up for Scully Offline; Set out at Scully Offline'
WHERE step_number = 12;

UPDATE `STG-DEMMLER` SET pickup = 'T', setout = 'T',
  remarks = 'Demmler Offline — Pick up for Demmler Offline; Set out at Demmler Offline'
WHERE step_number = 12;
