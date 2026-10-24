"""Pinned-artifact preflight and full-chip comparison for authorized 26102402 update."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUDIT = ROOT/'build/exposure_flash_audit'
DEPLOY = ROOT/'build/exposure_deploy'
OLD = ROOT/'build/clipping_flash_audit/programmed_flash.bin'
BIT_HASH = '5C5660BC97F80D0816C5BCC1554384DE83F4CC86A3BFE569795CD1178CCE7523'
OLD_HASH = '7D2B3A6D1DE29BD42B442302C2F6AB743976839706372F5107AF6D7898D4EC5E'


def digest(data):
    return hashlib.sha256(data).hexdigest().upper()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('preflight', 'verify'))
    args = parser.parse_args()
    old = OLD.read_bytes()
    assert len(old) == 16777216 and digest(old) == OLD_HASH, 'Wrong verified baseline'
    bit = (DEPLOY/'instrument_exposure.bit').read_bytes()
    assert digest(bit) == BIT_HASH, 'Candidate bit changed since hardware acceptance'
    image = (DEPLOY/'instrument_exposure.bin').read_bytes()
    assert 0 < len(image) < len(old), 'Invalid image size'
    report = dict(status='PASS', version='26102402', previous_sha256=digest(old),
        bit_sha256=digest(bit), image_sha256=digest(image),
        mcs_sha256=digest((DEPLOY/'instrument_exposure.mcs').read_bytes()),
        scope='Experimental exposure/output/LED upgrade; no optical accuracy or complete external-IO signoff')
    AUDIT.mkdir(parents=True, exist_ok=True)
    if args.mode == 'preflight':
        assert not (AUDIT/'flash_before_program.bin').exists(), 'Prior attempt exists; inspect it'
        assert not (AUDIT/'programmed_flash.bin').exists(), 'Prior attempt exists; inspect it'
        gate = json.loads((ROOT/'build/exposure_hardware_20261024/buffered_acceptance/summary.json').read_text())
        assert gate['passed'] and gate['stop_confirmed'] and len(gate['cases']) >= 6
        by_name = {c['label']: c for c in gate['cases']}
        assert all(c['timing_passed'] and c['max_dropped'] == c['max_malformed'] == 0 for c in gate['cases'])
        assert by_name['200us_all']['results'] >= 3000 and by_name['200us_all']['invalid_results'] == 0
        assert by_name['200us_all']['injected_host_pause_ms'] == 100
        assert by_name['200us_all']['clipped_raw_frames'] == 0
        assert by_name['200us_1250Hz']['timestamp_result_hz'] == 1250
        assert abs(by_name['200us_833Hz']['timestamp_result_hz']-2500/3) < 1e-8
        assert gate['long_tail_interrupt']['passed'] and gate['handoff']['source_version'] == gate['handoff']['k_version'] == 0
        assert 'EXPOSURE_LED_NETLIST_AUDIT_PASS' in (ROOT/'build/exposure_hardware_20261024/led_netlist_audit.log').read_text()
        assert 'EXPOSURE_OFFLINE_BUILD_PASS' in (ROOT/'build/exposure_buffered_build.log').read_text()
        assert 'EXPOSURE_VOLATILE_PROGRAM_PASS' in (ROOT/'build/exposure_hardware_20261024/program_buffered.log').read_text()
        target = AUDIT/'preflight.json'
    else:
        before = (AUDIT/'flash_before_program.bin').read_bytes()
        actual = (AUDIT/'programmed_flash.bin').read_bytes()
        assert before == old, 'Live backup differs from expected previous image'
        assert len(actual) == len(before), 'Missing full readback'
        assert actual[:len(image)] == image, 'Programmed image differs'
        erase_end = (len(image)+65535)//65536*65536
        assert actual[erase_end:] == before[erase_end:], 'Unaddressed sectors changed'
        assert all(a == 255 or a == b for a, b in zip(actual[len(image):erase_end], before[len(image):erase_end])), 'Unexpected padding'
        report.update(image_bytes=len(image), erase_bound=erase_end,
            untouched_bytes=len(actual)-erase_end, backup_sha256=digest(before), readback_sha256=digest(actual))
        target = AUDIT/'flash_verify.json'
    with target.open('x', encoding='utf-8') as stream:
        json.dump(report, stream, indent=2)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
