# Integrated instrument status

The `instrument_frontend_usb` hierarchy combines the existing CCD frontend,
`instrument_core` (capture, DSP, calibration and S0/RESULT packetization), and
`fx2_transport` (byte/word conversion, XPM CDC FIFOs and slave-FIFO controller).

Full OOC synthesis completed on 2026-09-22 21:33:28 and was inspected on
2026-09-23 after the process handle expired. Evidence:

- `build/instrument_synth.log`: PROCESSOR_SYNTH_PASS, linked FFT/IFFT, no unresolved black boxes.
- `build/instrument_synth/utilization.rpt`: 25,703 LUTs, 26,834 registers,
  24 BRAM tiles and 86 DSPs on xc7a200tfbg484-2.
- `build/instrument_synth/timing_synth.rpt`: reported setup slack +1.778 ns
  and hold slack +0.127 ns under the current OOC constraints.
- `build/instrument_synth/processor.dcp`: integrated synthesized checkpoint.

These timing numbers are NOT board timing closure: external input/output delays,
board clocks/reset wiring, USB package pins, flag polarity, physical clock skew,
post-route CDC/bus-skew checks and FX2 reset/session alignment remain unqualified.
The initial frontend is still the previously hardware-tested 5 MHz profile;
the final high-speed acquisition requirement remains open. The new FX2 state
machine has only compile/synthesis evidence, not bus-level simulation or hardware
transfer evidence. No production bitstream has been generated or downloaded.

Next critical path: verified USB pin/polarity constraints and board wrapper,
essential FX2 bus transaction checks, full implementation, then actual J5
S0/command/ACK/distance exchange with the live host backend. Avoid repeating
already passing numerical unit tests unless a relevant datapath changes.
