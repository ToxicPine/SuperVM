#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import struct
from dataclasses import dataclass
from pathlib import Path


PT_LOAD = 1
PF_X = 1
PF_W = 2
PAGE_SIZE = 4096
EM_X86_64 = 62
CROSVM_KERNEL_MIN_ADDRESS = 0x200000


REQUIRED_CONFIG = {
    "CONFIG_SUPERVM_BOOT_SEAL": "y",
    "CONFIG_JUMP_LABEL": "n",
    "CONFIG_HAVE_STATIC_CALL_INLINE": "n",
    "CONFIG_CALL_THUNKS": "n",
    "CONFIG_FTRACE": "n",
    "CONFIG_KPROBES": "n",
    "CONFIG_KGDB": "n",
    "CONFIG_BPF_JIT": "n",
    "CONFIG_RANDOMIZE_BASE": "n",
    "CONFIG_KEXEC": "n",
    "CONFIG_KEXEC_FILE": "n",
    "CONFIG_HIBERNATION": "n",
    "CONFIG_LIVEPATCH": "n",
    "CONFIG_STRICT_KERNEL_RWX": "y",
}


@dataclass(frozen=True)
class LoadSegment:
    virtual_address: int
    physical_address: int
    memory_size: int
    flags: int

    def physical_for(self, virtual_address: int) -> int:
        if not (
            self.virtual_address
            <= virtual_address
            < self.virtual_address + self.memory_size
        ):
            raise ValueError("virtual address is outside this PT_LOAD segment")
        return self.physical_address + virtual_address - self.virtual_address


def elf_load_segments(path: Path) -> tuple[int, list[LoadSegment]]:
    with path.open("rb") as file:
        header = file.read(64)
        if header[:4] != b"\x7fELF":
            raise ValueError(f"{path} is not an ELF file")
        if len(header) < 52:
            raise ValueError(f"{path} has a truncated ELF header")

        elf_class = header[4]
        byte_order = header[5]
        endian = {1: "<", 2: ">"}.get(byte_order)
        if endian is None:
            raise ValueError(f"{path} has unsupported ELF byte order {byte_order}")

        if elf_class == 2:
            if len(header) < 64:
                raise ValueError(f"{path} has a truncated ELF64 header")
            machine = struct.unpack_from(endian + "H", header, 18)[0]
            phoff = struct.unpack_from(endian + "Q", header, 32)[0]
            phentsize = struct.unpack_from(endian + "H", header, 54)[0]
            phnum = struct.unpack_from(endian + "H", header, 56)[0]
            ph_format = endian + "IIQQQQQQ"
        elif elf_class == 1:
            machine = struct.unpack_from(endian + "H", header, 18)[0]
            phoff = struct.unpack_from(endian + "I", header, 28)[0]
            phentsize = struct.unpack_from(endian + "H", header, 42)[0]
            phnum = struct.unpack_from(endian + "H", header, 44)[0]
            ph_format = endian + "IIIIIIII"
        else:
            raise ValueError(f"{path} has unsupported ELF class {elf_class}")

        expected_size = struct.calcsize(ph_format)
        if phentsize < expected_size:
            raise ValueError(f"{path} has truncated ELF program headers")

        segments: list[LoadSegment] = []
        for index in range(phnum):
            file.seek(phoff + index * phentsize)
            program_header = file.read(expected_size)
            if len(program_header) != expected_size:
                raise ValueError(f"{path} has a truncated ELF program header")
            values = struct.unpack(ph_format, program_header)
            if elf_class == 2:
                kind, flags, _offset, vaddr, paddr, _filesz, memsz, _align = values
            else:
                kind, _offset, vaddr, paddr, _filesz, memsz, flags, _align = values
            if kind == PT_LOAD:
                segments.append(LoadSegment(vaddr, paddr, memsz, flags))

    if not segments:
        raise ValueError(f"{path} contains no PT_LOAD segments")
    return machine, segments


def system_map_symbols(path: Path) -> dict[str, int]:
    symbols: dict[str, int] = {}
    with path.open() as file:
        for line in file:
            fields = line.split()
            if len(fields) == 3:
                address, _kind, name = fields
                symbols[name] = int(address, 16)
    return symbols


def kernel_config(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    with path.open() as file:
        for raw_line in file:
            line = raw_line.rstrip("\n")
            if line.startswith("CONFIG_") and "=" in line:
                name, value = line.split("=", 1)
                values[name] = value
            elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
                values[line[2 : -len(" is not set")]] = "n"
    return values


def validate_kernel_config(values: dict[str, str]) -> None:
    mismatches = {
        name: (expected, values.get(name, "n"))
        for name, expected in REQUIRED_CONFIG.items()
        if values.get(name, "n") != expected
    }
    if mismatches:
        details = ", ".join(
            f"{name}={actual} (expected {expected})"
            for name, (expected, actual) in mismatches.items()
        )
        raise ValueError(
            f"kernel configuration does not satisfy range producer policy: {details}"
        )


def validate_elf_boot(path: Path, segments: list[LoadSegment]) -> None:
    with path.open("rb") as file:
        header = file.read(64)
    if len(header) != 64 or header[:6] != b"\x7fELF\x02\x01":
        raise ValueError("direct x86-64 boot requires a little-endian ELF64 image")
    entry = struct.unpack_from("<Q", header, 24)[0]
    if (
        min(segment.physical_address for segment in segments)
        < CROSVM_KERNEL_MIN_ADDRESS
    ):
        raise ValueError("ELF load segment is below crosvm's minimum kernel address")
    # Linux's startup_64 can live in a RW init PT_LOAD segment. Crosvm loads
    # physical segments without enforcing their ELF permission flags at boot.
    if not any(
        segment.physical_address
        <= entry
        < segment.physical_address + segment.memory_size
        for segment in segments
    ):
        raise ValueError("ELF entry is not inside a physical load segment")


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) & -alignment


def align_down(value: int, alignment: int) -> int:
    return value & -alignment


def segment_containing(
    virtual_address: int, segments: list[LoadSegment]
) -> LoadSegment:
    for segment in segments:
        if (
            segment.virtual_address
            <= virtual_address
            < segment.virtual_address + segment.memory_size
        ):
            return segment
    raise ValueError(
        f"virtual address {virtual_address:#x} is outside every PT_LOAD segment"
    )


def image_range(
    name: str,
    first_symbol: str,
    last_symbol: str,
    symbols: dict[str, int],
    segments: list[LoadSegment],
) -> dict[str, int]:
    try:
        virtual_start = align_up(symbols[first_symbol], PAGE_SIZE)
        virtual_end = align_down(symbols[last_symbol], PAGE_SIZE)
    except KeyError as error:
        raise ValueError(f"System.map lacks required symbol {error.args[0]}") from error

    if virtual_end <= virtual_start:
        raise ValueError(f"{name} contains no complete pages")

    segment = segment_containing(virtual_start, segments)
    if segment.flags & PF_W:
        raise ValueError(f"{name} lies in a writable PT_LOAD segment")
    segment_page_end = align_up(
        segment.virtual_address + segment.memory_size, PAGE_SIZE
    )
    if virtual_end > segment_page_end:
        raise ValueError(f"{name} crosses its PT_LOAD segment")

    physical_start = segment.physical_for(virtual_start)
    # Linker symbols commonly include the zero-filled tail of the last page,
    # beyond p_memsz but before its page-aligned end. It has the same linear
    # virtual-to-physical translation as the rest of the segment.
    physical_end = segment.physical_address + virtual_end - segment.virtual_address
    if physical_start % PAGE_SIZE or physical_end % PAGE_SIZE:
        raise ValueError(f"{name} did not map to page-aligned physical addresses")

    return {
        "guestPhysicalStart": physical_start,
        "length": physical_end - physical_start,
    }


def immutable_text_ranges(
    symbols: dict[str, int], segments: list[LoadSegment]
) -> list[dict[str, int]]:
    # Only core text is sealed. Runtime static-call trampolines must retain
    # writable pages; rodata includes metadata and is deliberately not inferred
    # immutable merely from ELF segment permissions.
    text_range = image_range("kernel-text", "_text", "_etext", symbols, segments)
    trampoline_start = align_down(symbols["__static_call_text_start"], PAGE_SIZE)
    trampoline_end = align_up(symbols["__static_call_text_end"], PAGE_SIZE)
    if not (
        symbols["_text"]
        <= symbols["__static_call_text_start"]
        <= symbols["__static_call_text_end"]
        <= symbols["_etext"]
    ):
        raise ValueError("static-call trampolines lie outside core text")
    text_segment = segment_containing(symbols["_text"], segments)
    if not text_segment.flags & PF_X:
        raise ValueError("core text does not lie in an executable PT_LOAD segment")
    excluded_start = (
        text_segment.physical_address + trampoline_start - text_segment.virtual_address
    )
    excluded_end = (
        text_segment.physical_address + trampoline_end - text_segment.virtual_address
    )
    start = text_range["guestPhysicalStart"]
    end = start + text_range["length"]
    ranges = []
    for first, last in [
        (start, min(end, excluded_start)),
        (max(start, excluded_end), end),
    ]:
        if first < last:
            ranges.append({"guestPhysicalStart": first, "length": last - first})
    if not ranges:
        raise ValueError("no immutable core text pages remain")

    return ranges


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vmlinux", required=True, type=Path)
    parser.add_argument("--kernel-image", required=True, type=Path)
    parser.add_argument("--system-map", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    machine, segments = elf_load_segments(args.vmlinux)
    if machine != EM_X86_64:
        raise ValueError(
            "schema version 1 linked-physical maps support only x86-64; "
            f"vmlinux uses ELF machine {machine}"
        )
    symbols = system_map_symbols(args.system_map)
    validate_kernel_config(kernel_config(args.config))
    if args.kernel_image.resolve() != args.vmlinux.resolve():
        raise ValueError(
            "kernel-image must point to the exact vmlinux used for the ranges"
        )
    validate_elf_boot(args.vmlinux, segments)
    ranges = immutable_text_ranges(symbols, segments)

    document = {
        "schemaVersion": 1,
        "pageSize": PAGE_SIZE,
        "ranges": ranges,
    }
    args.output.write_text(json.dumps(document, indent=2) + "\n")


if __name__ == "__main__":
    main()
