# Changelog

## [Unreleased]

### Fixed

- `ld --out-implib` failed on every ELF link with "failed to generate import
  library". The import library inherited a flag that only applies to the
  linked output.
- `elfedit --enable-x86-feature` and `--disable-x86-feature` were missing, and
  BFD read files without `mmap`: the build guessed that `mmap` didn't work.
- objdump and readelf look for separate debug files in `/usr/lib/debug`
  instead of a build path.
- The README says what's missing: zstd-compressed debug sections, default
  library directories for `ld`, `gprofng` and linker plugins.

### Changed

- The upstream test suites for binutils, gas, ld, libctf, libsframe,
  libiberty, bfd, opcodes and gprof run on native Linux builds.

## [2.46-2] - 2026-09-26

### Added

- `coffdump`, `srconv` and `sysdump`. binutils builds them on every platform,
  but they were left out of the binary.

### Fixed

- On Windows, `windres` converting a `.res` file to a COFF object wrote 8 bytes
  of leftover memory into every resource, so the same input gave a different
  object on each run. Those bytes are now zero. The binaries released so far
  happened to write zeros there anyway.
