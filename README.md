# binutils

The [GNU binary utilities](https://www.gnu.org/software/binutils/) — `objdump`, `readelf`, `nm`, `ar`, `strip`, `objcopy`, the `ld` and `ld.gold` linkers, the `as` assembler, `gprof`, and the `dlltool`/`windres` family — in a single self-contained binary that reads every architecture's object files. Built for Linux, macOS and Windows; the exact program set is whatever each platform's binutils can build (see [Build notes](#build-notes)).

[![CI](https://github.com/unpins/binutils/actions/workflows/binutils.yml/badge.svg)](https://github.com/unpins/binutils/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install binutils`.

## Usage

Run it with [unpin](https://github.com/unpins/unpin) — a bare `binutils` runs `objdump`:

```bash
unpin binutils -d /bin/ls
```

To put every command — `objdump`, `readelf`, `nm`, `ar`, `objcopy`, `strip`, and (where your platform supports them) `ld`, `ld.gold`, `as`, `gprof` and more — onto your PATH:

```bash
unpin install binutils
```

`unpin info binutils` lists every command the install creates on your platform.

## Man pages

Each applet's man page is embedded — read one with `unpin man binutils <applet>`, e.g. `unpin man binutils objdump`.

## Build locally

```bash
nix build github:unpins/binutils
./result/bin/binutils --version
```

Or run directly:

```bash
nix run github:unpins/binutils -- --version
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/binutils/releases) page has standalone binaries for manual download.

## Build notes

- One multicall binary holds every program. `binutils` is the canonical name; the
  individual programs (`objdump`, `readelf`, `nm`, …) are recreated as commands at
  `unpin install`. They share the static `libbfd`, `libopcodes`, `libctf`,
  `libsframe`, `libiberty` (and, on Linux, `libgold`) archives, linked once.
- Built with `--enable-targets=all`, so a single `objdump`/`readelf`/`ld`
  handles object files for any architecture (x86, ARM, RISC-V, PowerPC, …), not
  just the host's. `as` assembles for the host architecture only (the assembler
  is single-target by nature).
- The program set is **maximal per platform** — every program that platform's
  binutils can build is folded in, so it differs by OS:
  - **Linux** — the full toolkit: the inspection/manipulation programs, the `ld`
    (BFD) and `ld.gold` linkers, the `as` assembler, `gprof`, `dwp`, and the PE
    `dlltool`/`dllwrap`/`windres`/`windmc` tools.
  - **Windows** — the same, **minus `ld.gold`/`dwp`** (the gold linker only
    targets ELF, so binutils' own configure builds it nowhere else).
  - **macOS** — the inspection/manipulation programs plus the PE
    `dlltool`/`dllwrap`/`windres`/`windmc` tools. GNU `ld`, `as`, `gprof` and
    `gold` have no Mach-O backend, so binutils' configure drops them on Darwin;
    the inspection programs still read every architecture (incl. Mach-O).
- `ld.gold`/`dwp` (Linux) are C++; their runtime is folded in statically. On
  macOS `windres`/`windmc` need `iconv`, which lives in `libiconv` rather than
  `libSystem`, so `libiconv.a` is folded in statically — the binary stays
  `libSystem`-only with no companion libraries.
- `c++filt` is present and runs as `binutils c++filt …`, but the `+` characters
  are outside the command-name charset, so it isn't recreated as a standalone
  PATH command at `unpin install`.
