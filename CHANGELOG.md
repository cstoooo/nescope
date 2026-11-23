# Changelog

## 0.1.1

- Fix WAV encoding so mixer silence maps to PCM zero instead of full-scale negative DC.
- Return non-zero CLI exits for malformed commands, files, options and numeric arguments.
- Validate `--frames`, `--limit` and `--pc` instead of silently accepting invalid values.
- Add persistent twelve-bit iNES bank-count coverage.
- Add CLI integration tests for inspect, run, trace, PNG, WAV and battery saves.
- Run tests and type checks on wasm, wasm-gc, js and native in CI.
- Update trace and APU documentation to match the implemented behavior.

## 0.1.0

- Initial CPU, PPU, cartridge, mapper, save, PNG and audio implementation.
