#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_expect() {
  local expected="$1"
  shift
  set +e
  "$@" >"$tmp/output.txt" 2>&1
  local actual=$?
  set -e
  if [ "$actual" -ne "$expected" ]; then
    echo "expected exit $expected, got $actual: $*" >&2
    cat "$tmp/output.txt" >&2
    exit 1
  fi
}

run_expect 0 moon run cmd/main -- --inspect internal/fixtures/nestest.nes
grep -q 'mapper     NROM' "$tmp/output.txt"
grep -q 'reset      C004' "$tmp/output.txt"

cp internal/fixtures/nestest.nes "$tmp/battery.nes"
python3 - "$tmp/battery.nes" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = bytearray(path.read_bytes())
data[6] |= 0x02
path.write_bytes(data)
PY

run_expect 0 moon run cmd/main -- --run "$tmp/battery.nes" --frames 2 \
  --write-png "$tmp/frame.png" --write-wav "$tmp/audio.wav"
grep -q 'frames     2' "$tmp/output.txt"

python3 - "$tmp/frame.png" "$tmp/audio.wav" "$tmp/battery.srm" <<'PY'
from pathlib import Path
import struct
import sys
import wave

png = Path(sys.argv[1]).read_bytes()
assert png[:8] == b'\x89PNG\r\n\x1a\n'
assert struct.unpack('>II', png[16:24]) == (256, 240)
assert Path(sys.argv[3]).stat().st_size == 8192
with wave.open(sys.argv[2], 'rb') as wav:
    assert wav.getnchannels() == 1
    assert wav.getsampwidth() == 2
    assert wav.getframerate() == 44100
    assert wav.getnframes() > 0
    data = wav.readframes(min(wav.getnframes(), 16))
    samples = struct.unpack('<' + 'h' * (len(data) // 2), data)
    assert samples and all(sample == 0 for sample in samples), samples
PY

run_expect 0 moon run cmd/main -- --trace internal/fixtures/nestest.nes --limit 5
grep -q 'C004.*SEI' "$tmp/output.txt"
grep -q 'C006.*LDX #\$FF' "$tmp/output.txt"

printf '\xA9\x01\x85\x10\x4C\x00\xC0' >"$tmp/flat.bin"
run_expect 0 moon run cmd/main -- --trace "$tmp/flat.bin" --limit 3
grep -q 'C000.*LDA #\$01' "$tmp/output.txt"
grep -q 'C002.*STA \$10' "$tmp/output.txt"

run_expect 2 moon run cmd/main --
run_expect 2 moon run cmd/main -- --unknown
run_expect 1 moon run cmd/main -- --inspect "$tmp/missing.nes"
run_expect 1 moon run cmd/main -- --inspect README.mbt.md
run_expect 1 moon run cmd/main -- --run internal/fixtures/nestest.nes --frames nope
run_expect 1 moon run cmd/main -- --run internal/fixtures/nestest.nes --unknown value
run_expect 1 moon run cmd/main -- --trace "$tmp/flat.bin" --pc xyz

echo "CLI smoke tests passed"
