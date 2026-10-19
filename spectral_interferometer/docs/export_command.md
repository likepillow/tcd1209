# EXPORT command (SPIF v1 extension, 2026-09-22)

Kind 0x23, payload length 4: little-endian unsigned 32-bit S0 selection period.
Zero disables S0 export, one requests every frame, N requests one opportunity
in N frames. ADC acquisition and distance computation are unchanged. An occupied
S0 buffer skips the complete selected export frame and increments its busy count.

The normal header and CRC rules apply. `config_packet_rx` validates the complete
packet before offering it. `calibration_loader` atomically updates
`export_period_frames` after consuming all four bytes and then offers status-0
ACK with the original command sequence. This ACK confirms the configuration
register, not that a selected spectrum has already reached the computer. The
S0 tap samples configuration on its next input-frame start. Already buffered
or transmitting S0 remains intact, including when the new period is zero.
S/K calibration versions are unchanged. Reset restores period 1.

Host helper: `export_command(period_frames, sequence)`. Eight protocol tests
pass including export round-trips for 0, 1, 2, 100 and uint32 maximum, plus invalid
argument rejection.

`scripts/test_export_control.ps1` passed in Vivado 2018.3 at 2026-09-22 15:58:03:
bad CRC leaves the reset period intact without a reply, no register update
occurs before CRC completion, periods 0/5/uint32-max update before ACK admission,
withheld scheduler grant holds the reply, and no S/K write/begin/commit occurs.
Three complete ACK packets were emitted under byte-output stalls. This targeted
test checks ACK timing/status, not its wire bytes. The existing S/K regression
also finished exit 0, including its host ACK byte/CRC/version comparison.

Remaining: connect the control output to the production export wrapper and test
the resulting frame selection, add GUI controls and export-skip telemetry, and
qualify the actual hardware transport. The targeted control test alone does not
prove end-to-end hardware configuration.

## Integrated selection run verified

The actual-FFT packet-mode test now instantiates `s0_measurement_packet_tx`
instead of duplicating its internal connection. `calibration_control` drives
its period register directly. Host-generated input contains SOURCE, K_WEIGHTS,
then EXPORT(period=2). Expected output is three ACKs, S0 frames 198/201/203,
and all four distance results 200..203. Exactly two rate skips and zero busy
skips/acquisition drops are required. Internal S1/S2 and phase numerical checks
remain enabled. Vivado completed at 2026-09-22 16:11:14 with both simulation
PASS markers. After the process handle expired, both independent Python
checkers were rerun against the resulting files and exited zero. They verified
the selected RAW frame list, all four RESULT frames, three ACKs, complete wire
bytes/CRC, normalization, phase, and fixed-point distance. No acquisition drops
or busy skips occurred, and exactly two intentional rate skips were asserted.
Distance latencies were 28744/29084/28738/28752 system clocks. This proves the
finite digital command-to-selection connection through the production export
wrapper, not physical USB operation or indefinite full-rate processing.
