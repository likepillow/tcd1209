"""Preflight and full-chip verification for the explicitly authorized update."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUDIT = ROOT/'build/clipping_flash_audit'
OLD = ROOT/'build/control_flash_audit/programmed_flash.bin'
DEPLOY = ROOT/'build/clipping_deploy'


def digest(data):
    return hashlib.sha256(data).hexdigest().upper()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['preflight', 'verify'])
    args = parser.parse_args()
    previous = OLD.read_bytes()
    assert len(previous) == 16777216
    assert digest(previous) == 'AEA195735DA41AC1730FE6827D9387EE3BB9A8618476FDBADE704C924643DFF9', 'Baseline hash mismatch'
    bit = (DEPLOY/'instrument_clipping.bit').read_bytes()
    assert digest(bit) == '7B1ADC9B5680D0FF34C31CA44EDC8FBCC7F07F7D4CC5212CCB6BD1531C135412', 'Candidate bit changed'
    image = (DEPLOY/'instrument_clipping.bin').read_bytes()
    assert 0 < len(image) < len(previous)
    report = {'status': 'PASS', 'version': '26100301', 'previous_sha256': digest(previous),
              'bit_sha256': digest(bit), 'image_sha256': digest(image),
              'mcs_sha256': digest((DEPLOY/'instrument_clipping.mcs').read_bytes())}
    AUDIT.mkdir(parents=True, exist_ok=True)
    if args.mode == 'preflight':
        assert not (AUDIT/'flash_before_program.bin').exists(), 'Previous attempt exists; inspect before retry'
        assert not (AUDIT/'programmed_flash.bin').exists(), 'Previous attempt exists; inspect before retry'
        gate = json.loads((ROOT/'build/positions_20261004/weak_result_rate/summary.json').read_text(encoding='utf-8'))
        assert gate['rate_gate_passed'] and gate['stop_confirmed'] and gate['invalid_results'] == 0
        assert gate['result_packets'] >= 5000 and gate['host_valid_result_hz'] >= 1000
        assert gate['raw_frames_checked'] >= 50 and gate['clipped_raw_frames'] == 0
        rejection = json.loads((ROOT/'build/positions_20261003/clipping_rejection/summary.json').read_text(encoding='utf-8'))
        assert rejection['clipping_rejection_gate_passed'] and rejection['stop_confirmed']
        assert 'REGISTER.USR_ACCESS=26100301' in (ROOT/'build/positions_20261004/jtag_identity.log').read_text()
        assert 'CLIPPING_CANDIDATE_BUILD_PASS' in (ROOT/'build/clipping_build.log').read_text()
        report['scope'] = 'Clipping protection and nonrail processing throughput; not optical distance accuracy'
        target = AUDIT/'preflight.json'
    else:
        before = (AUDIT/'flash_before_program.bin').read_bytes()
        actual = (AUDIT/'programmed_flash.bin').read_bytes()
        assert before == previous, 'Backup differs from verified baseline'
        assert len(actual) == len(before)
        assert actual[:len(image)] == image, 'Programmed image mismatch'
        erase_end = (len(image)+65535)//65536*65536
        assert actual[erase_end:] == before[erase_end:], 'Unaddressed sectors changed'
        assert all(a == 255 or a == b for a, b in zip(actual[len(image):erase_end], before[len(image):erase_end])), 'Unexpected erase padding'
        report.update(image_bytes=len(image), erase_bound=erase_end,
                      untouched_bytes=len(actual)-erase_end, backup_sha256=digest(before),
                      readback_sha256=digest(actual))
        target = AUDIT/'flash_verify.json'
    with target.open('x', encoding='utf-8') as stream:
        json.dump(report, stream, indent=2)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
