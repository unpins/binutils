# Changelog

## [Unreleased]

## [2.46-2] - 2026-09-26

### Added

- `coffdump`, `srconv` and `sysdump`. binutils builds them on every platform,
  but they were left out of the binary.

### Fixed

- On Windows, `windres` converting a `.res` file to a COFF object wrote 8 bytes
  of leftover memory into every resource, so the same input gave a different
  object on each run. Those bytes are now zero. The binaries released so far
  happened to write zeros there anyway.
