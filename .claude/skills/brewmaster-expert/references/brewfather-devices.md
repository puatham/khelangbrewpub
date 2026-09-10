# Brewfather, iSpindel and RAPT

Facts checked against current Brewfather docs on 2026-09-10.

## API

- Use REST API v2 for new integrations.
- API v1 is deprecated.
- API data are returned in metric units.
- Re-check documentation before implementation because API behavior may change.

## Equipment profiles

Brewfather equipment profiles depend on system-specific batch volume, efficiency, losses and boil-off. Calibrate against real batches and distinguish recoverable mash-tun deadspace from unrecoverable mash-tun loss.

For multi-vessel systems, explicitly model/measure HLT deadspace/minimum HLT water requirements where relevant.

## iSpindel

Current official integration guidance:
- HTTP logging interval 900 seconds or higher;
- values sent more frequently than every 15 minutes are ignored;
- default gravity expectation is Plato, converted to SG by Brewfather;
- add `[SG]` to the iSpindel name if the formula sends SG;
- attach the device to the batch after its first reading appears.

## RAPT

Current RAPT Cloud integration supports RAPT Pill and RAPT Temperature Controller. It logs gravity (SG), temperature, target temperature when available, battery and RSSI. Data sent more frequently than every 15 minutes are ignored; attach the device to the desired batch.

## Interpretation

Keep planned recipe values, manual measurements and device telemetry separate. Use floating devices primarily for trend/state detection unless calibration and agreement justify stronger confidence.
