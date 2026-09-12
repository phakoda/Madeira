#!/usr/bin/env python3
"""Read an EXE's architecture without executing it or requiring a compiler."""
import argparse
import json
import struct
from pathlib import Path


def inspect(path):
    with path.open('rb') as stream:
        dos = stream.read(64)
        if len(dos) != 64 or dos[:2] != b'MZ':
            raise ValueError('Missing DOS executable header')
        pe_offset = struct.unpack_from('<I', dos, 60)[0]
        stream.seek(pe_offset)
        coff = stream.read(24)
        if len(coff) != 24 or coff[:4] != b'PE\0\0':
            raise ValueError('Missing PE/COFF header')
        machine = struct.unpack_from('<H', coff, 4)[0]
        optional_size = struct.unpack_from('<H', coff, 20)[0]
        optional = stream.read(optional_size)
        if len(optional) != optional_size or len(optional) < 2:
            raise ValueError('Truncated optional header')
        magic = struct.unpack_from('<H', optional)[0]
        if magic not in (0x10b, 0x20b):
            raise ValueError(f'Unexpected optional-header format: 0x{magic:04X}')
        directories = 96 if magic == 0x10b else 112
        clr_rva, clr_size = (0, 0)
        directory_count = struct.unpack_from('<I', optional, directories - 4)[0] if len(optional) >= directories else 0
        if directory_count >= 15 and len(optional) >= directories + 15 * 8:
            clr_rva, clr_size = struct.unpack_from('<II', optional, directories + 14 * 8)
    return {
        'file': path.name,
        'machine': f'0x{machine:04X}',
        'architecture': {0x14c: 'x86 (32-bit)', 0x8664: 'x64 (64-bit)',
                         0xaa64: 'ARM64', 0xa641: 'ARM64EC', 0xa64e: 'ARM64X'}.get(machine, 'unknown'),
        'format': 'PE32' if magic == 0x10b else 'PE32+',
        'has_clr_header': bool(clr_rva and clr_size),
        'note': 'A CLR header requires additional AnyCPU/CorFlags inspection.' if clr_rva and clr_size
                else 'No CLR header; this is not a .NET AnyCPU executable.',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files', type=Path, nargs='+')
    args = parser.parse_args()
    failed = False
    for path in args.files:
        try:
            print(json.dumps(inspect(path), ensure_ascii=False))
        except (OSError, ValueError, struct.error) as error:
            failed = True
            print(json.dumps({'file': path.name, 'error': str(error)}))
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())
