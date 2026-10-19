"""Read-only HEX/IIC consistency audit; instruction patterns are not live readback."""
import argparse
import hashlib
import json
from pathlib import Path


def read_hex(path):
    memory = {}
    base = 0
    for line in path.read_text().splitlines():
        if not line:
            continue
        if not line.startswith(":"):
            raise ValueError("Not Intel HEX")
        record = bytes.fromhex(line[1:])
        if sum(record) & 255 or len(record) != record[0] + 5:
            raise ValueError("HEX checksum/length error")
        size, kind = record[0], record[3]
        address = int.from_bytes(record[1:3], "big")
        if kind == 0:
            for offset, value in enumerate(record[4:4+size]):
                memory[base+address+offset] = value
        elif kind == 1:
            return memory
        elif kind == 4:
            base = int.from_bytes(record[4:6], "big") << 16
        else:
            raise ValueError(f"Unsupported HEX record {kind}")
    raise ValueError("Missing HEX EOF")


def read_iic(path):
    blob = path.read_bytes()
    if len(blob) < 8 or blob[0] != 0xC2:
        raise ValueError("Expected FX2 C2 EEPROM image")
    memory, offset = {}, 8
    while offset+4 <= len(blob):
        count = int.from_bytes(blob[offset:offset+2], "big")
        address = int.from_bytes(blob[offset+2:offset+4], "big")
        offset += 4
        size = count & 0x7fff
        if offset+size > len(blob):
            raise ValueError("Truncated IIC record")
        for i, value in enumerate(blob[offset:offset+size]):
            if address+i in memory:
                raise ValueError("Overlapping IIC records")
            memory[address+i] = value
        offset += size
        if count & 0x8000:
            if offset != len(blob):
                raise ValueError("Trailing IIC bytes")
            return memory
    raise ValueError("Missing IIC final record")


def audit(folder):
    hex_memory = read_hex(folder / "slave.hex")
    iic_memory = read_iic(folder / "slave.iic")
    mismatches = [a for a,v in hex_memory.items() if iic_memory.get(a) != v]
    registers = {0xe601:"IFCONFIG",0xe602:"PINFLAGSAB",0xe603:"PINFLAGSCD",
                 0xe609:"FIFOPINPOLAR",0xe612:"EP2CFG",0xe614:"EP6CFG",
                 0xe618:"EP2FIFOCFG",0xe61a:"EP6FIFOCFG",
                 0xe624:"EP6AUTOINLENH",0xe625:"EP6AUTOINLENL"}
    patterns = []
    for pc in sorted(hex_memory):
        seq = bytes(hex_memory.get(pc+i, 0) for i in range(6))
        address = int.from_bytes(seq[1:3], "big")
        # MOV DPTR,#addr; MOV A,#value; MOVX @DPTR,A.
        # Byte-pattern evidence only: no claim of reachability/disassembly.
        if seq[0] == 0x90 and seq[3] == 0x74 and seq[5] == 0xf0 and address in registers:
            patterns.append(dict(pc=f"0x{pc:04X}", register=registers[address], value=f"0x{seq[4]:02X}"))
    return dict(hex_bytes=len(hex_memory), iic_bytes=len(iic_memory),
                hex_matches_iic=not mismatches, mismatch_addresses=mismatches,
                iic_sha256=hashlib.sha256((folder/"slave.iic").read_bytes()).hexdigest(),
                immediate_write_patterns=patterns,
                limitation="Static artifact comparison, not running firmware register readback; patterns may omit other instruction forms")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    result = audit(args.folder)
    output = json.dumps(result, indent=2)
    if args.report:
        with args.report.open("x", encoding="utf-8") as stream:
            stream.write(output+"\n")
    print(output)
    if not result["hex_matches_iic"]:
        raise SystemExit(1)
