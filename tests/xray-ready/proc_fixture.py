#!/usr/bin/env python3
"""ELF identification for synthetic proc tables, not a readiness/port marker.

Legacy fixtures encode each proc word as little-endian, irrespective of the test
host. The self/exe identity must describe that same explicit fixture ABI.
"""
from pathlib import Path
import sys


def elf_ident(little=True, elf_class=2):
    if not isinstance(little, bool):
        raise ValueError('explicit boolean byte order required')
    return b'\x7fELF' + bytes((elf_class, 1 if little else 2, 1)) + bytes(9)


def seed_elf(root, little=True):
    target = Path(root) / 'proc/self/exe'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(elf_ident(little))
    return target


if __name__ == '__main__':
    seed_elf(sys.argv[1])
