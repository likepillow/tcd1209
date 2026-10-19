# S0-only export decision (2026-09-22)

The user permits omitting S1/S2 output and configurable-rate S0 output. This
does not remove any internal normalization, FFT/IFFT, phase or distance work.
Acquisition and distance calculation/output must remain per frame.

The previous unbuffered RAW/SPECTRUM/RESULT/CONTROL joint simulation terminated
with `Fatal: Timeout` at simulated 3 ms (Vivado exit 2026-09-22 15:20:19).
It did not pass. Static packet-lock/backpressure dependencies and excessive
aggregate export demand motivate decoupled frame publication; timeout alone
does not isolate its precise cause.

`s0_export_buffer.v` is a new nonblocking tap for a validated S0 input stream:

- Period 0 disables output; N selects one in N frames. Period changes take
  effect at the next first pixel, which becomes a new selection opportunity.
- A selected frame is accepted only if the complete-frame buffer is free.
- Busy selected frames are skipped whole and counted separately from rate
  skips. These are export skips, not acquisition-frame losses.
- Only complete buffered frames are published for packet transmission.
- The input is always ready while out of reset, including when output stalls.
- Input must have correct first/last markers and frame IDs. Selected malformed
  frames fault the buffer until coordinated reset; this is not an ADC validator.

Vivado 2018.3 unit test `scripts/test_s0_export_buffer.ps1` passed at 15:26:05:
DEPTH=16, blocked output while four frames arrive, one rate-selected busy skip,
two rate skips, exact first-frame readback, then disabled export. This is not
yet a 1024-pixel integrated or physical USB qualification.

Remaining: connect this tap to acquisition and RAW packetization, consume S1/S2
without export backpressure, test configurable selection and sustained frame
processing with actual FFT IP, expose configuration and skip counts to host,
then integrate/qualify the FX2 physical path. The existing measurement wrapper
still contains the four-channel path; it has not yet been replaced or verified
with this buffer. No new hardware image was downloaded for this test.

## Joint-test integration in progress

The packet-mode `tb_processor.sv` now connects acquisition RAW through the
1024-pixel S0 export buffer into measurement RAW packetization. SPECTRUM
packet requests are disabled; internal S1/S2 are consumed and still numerically
checked. The test deliberately uses period=1 initially, and asserts no export
skips as well as no acquisition loss at its configured simulated bandwidth.
The expected wire output is two configuration ACKs, five complete RAW packets
(including the uncalibrated source-capture frame), and four distance packets.
The host byte/CRC checker rejects any S1/S2 packet in this mode.

This revised joint simulation passed (Vivado exit 2026-09-22 15:39:35, script
exit 0). Four continuous 2048-pixel frames at simulated 12.5 MHz / 170.02 us
frame period had zero acquisition drops and zero export skips. Distance
latencies were 28745, 29085, 28738, 28753 system clocks. Python confirmed exact
normalization and fixed-point distance accumulation, phase error below
7.91e-7 rad on valid frames, and all eleven output packets including CRC.
This finite simulation does not qualify sustained physical USB or CCD timing.

`s0_measurement_packet_tx.v` now encapsulates the tested buffer/packetizer
connection with a period input and separate export-skip counters. Its S0
timestamps are explicitly invalid until acquisition timestamps are integrated;
result timestamps are caller supplied. Its RESULT path is lossless but still
backpressurable, so sustained downstream capacity remains a requirement.
The wrapper itself is undergoing OOC synthesis and needs direct integration
testing; the passing joint test used the equivalent discrete connection.
Host-configurable period, skip telemetry and physical integration remain open.
