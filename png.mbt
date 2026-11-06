// Writing a frame to a PNG file.
//
// The PPU produces palette indices, not colours, so something has to turn an
// index into an RGB triple before the picture means anything. The NES's palette
// is a set of 64 analog levels that differ between revisions of the console; the
// table below is the widely used 2C02 approximation, which is what every
// emulator screenshot you have seen was drawn with.
//
// The PNG writer is written out rather than pulled from a dependency because the
// format needed here is the smallest possible one: 8-bit RGB, no interlacing, one
// filter byte per row. That is about forty lines, and it keeps the module free of
// imports so it can compile to any target.

///|
/// The 64 colours of the NES palette as 0xRRGGBB.
///
/// The order is the one the PPU's `$3F00` entries index, so a palette byte can be
/// used directly as an index. Several entries are duplicates because the
/// hardware genuinely produces the same level twice.
fn nes_palette() -> FixedArray[UInt32] {
  [
    0x666666, 0x002A88, 0x1412A7, 0x3B00A4, 0x5C007E, 0x6E0040, 0x6C0600, 0x561D00,
    0x333500, 0x0B4800, 0x005200, 0x004F08, 0x00404D, 0x000000, 0x000000, 0x000000,
    0xADADAD, 0x155FD9, 0x4240FF, 0x7527FE, 0xA01ACC, 0xB71E7B, 0xB53120, 0x994E00,
    0x6B6D00, 0x388700, 0x0C9300, 0x008F32, 0x007C8D, 0x000000, 0x000000, 0x000000,
    0xFFFEFF, 0x64B0FF, 0x9290FF, 0xC676FF, 0xF36AFF, 0xFE6ECC, 0xFE8170, 0xEA9E22,
    0xBCBE00, 0x88D800, 0x5CE430, 0x45E082, 0x48CDDE, 0x4F4F4F, 0x000000, 0x000000,
    0xFFFEFF, 0xC0DFFF, 0xD3D2FF, 0xE8C8FF, 0xFBC2FF, 0xFEC4EA, 0xFECCC5, 0xF7D8A5,
    0xE4E594, 0xCFEF96, 0xBDF4AB, 0xB3F3CC, 0xB5EBF2, 0xB8B8B8, 0x000000, 0x000000,
  ]
}

///|
/// The RGB triple the NES palette gives for a palette index.
///
/// Indices are six bits wide, so the table always answers; the mask is there
/// because a frame buffer that has been written by a buggy renderer could hold
/// anything and reading past the end would panic rather than produce a wrong
/// colour.
pub fn nes_colour(index : UInt32) -> (UInt32, UInt32, UInt32) {
  let rgb = nes_palette()[(index & 0x3F).reinterpret_as_int()]
  ((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
}

///|
/// Encodes a frame of palette indices as a PNG file.
///
/// `frame` is the PPU's 256x240 buffer: one palette index per pixel, row major.
/// The result is a complete PNG file, which is what makes it possible to look at
/// what the emulator drew without a window system.
pub fn encode_png(frame : FixedArray[Byte]) -> Bytes {
  // Each row is one filter byte followed by three bytes per pixel. A filter byte
  // of zero means "no prediction", which costs some compression ratio and saves
  // implementing the five prediction modes.
  let stride = 1 + SCREEN_WIDTH * 3
  let raw = Buffer::Buffer(size_hint=stride * SCREEN_HEIGHT)
  for y in 0..<SCREEN_HEIGHT {
    raw.write_byte(b'\x00')
    for x in 0..<SCREEN_WIDTH {
      let (r, g, b) = nes_colour(
        frame[y * SCREEN_WIDTH + x].to_int().reinterpret_as_uint(),
      )
      raw.write_byte(r.to_byte())
      raw.write_byte(g.to_byte())
      raw.write_byte(b.to_byte())
    }
  }
  let compressed = zlib_stored(raw.to_bytes())
  let out = Buffer::Buffer(size_hint=compressed.length() + 64)
  // The eight-byte signature every PNG file starts with.
  for byte in [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
    out.write_byte(byte.reinterpret_as_uint().to_byte())
  }
  // IHDR carries the dimensions and the pixel format: 8-bit depth, colour type 2
  // (truecolour), no interlace.
  let header = Buffer::Buffer(size_hint=13)
  write_u32(header, SCREEN_WIDTH.reinterpret_as_uint())
  write_u32(header, SCREEN_HEIGHT.reinterpret_as_uint())
  header.write_byte(b'\x08')
  header.write_byte(b'\x02')
  header.write_byte(b'\x00')
  header.write_byte(b'\x00')
  header.write_byte(b'\x00')
  write_chunk(out, "IHDR", header.to_bytes())
  write_chunk(out, "IDAT", compressed)
  write_chunk(out, "IEND", Bytes::new(0))
  out.to_bytes()
}

///|
/// Writes a PNG chunk: length, type, payload and a CRC over type plus payload.
fn write_chunk(out : Buffer, kind : String, payload : Bytes) -> Unit {
  write_u32(out, payload.length().reinterpret_as_uint())
  let checked = Buffer::Buffer(size_hint=4 + payload.length())
  for i in 0..<4 {
    checked.write_byte(
      kind.code_unit_at(i).to_int().reinterpret_as_uint().to_byte(),
    )
  }
  for i in 0..<payload.length() {
    checked.write_byte(payload.at(i))
  }
  let covered = checked.to_bytes()
  for i in 0..<covered.length() {
    out.write_byte(covered.at(i))
  }
  write_u32(out, crc32(covered))
}

///|
/// Writes a big-endian 32-bit value, which is the byte order every PNG field uses.
fn write_u32(out : Buffer, value : UInt32) -> Unit {
  out.write_byte(((value >> 24) & 0xFF).to_byte())
  out.write_byte(((value >> 16) & 0xFF).to_byte())
  out.write_byte(((value >> 8) & 0xFF).to_byte())
  out.write_byte((value & 0xFF).to_byte())
}

///|
/// The CRC-32 that PNG uses for its chunk checksums.
///
/// The polynomial is the reflected form of 0x04C11DB7, which is why the table is
/// generated by shifting right; using the non-reflected form produces a file that
/// looks correct in a hex dump and is rejected by every decoder.
fn crc32(bytes : Bytes) -> UInt32 {
  let mut crc = 0xFFFFFFFFU
  for i in 0..<bytes.length() {
    let index = ((crc ^ bytes.at(i).to_int().reinterpret_as_uint()) & 0xFF).reinterpret_as_int()
    crc = crc_table_entry(index) ^ (crc >> 8)
  }
  crc ^ 0xFFFFFFFFU
}

///|
/// One entry of the CRC-32 table, computed on demand.
///
/// A 256-entry table would be faster, but this runs once per chunk on a buffer
/// that is at most a few hundred kilobytes, and computing an entry costs eight
/// shifts against a table lookup plus an array read.
fn crc_table_entry(index : Int32) -> UInt32 {
  let mut value = index.reinterpret_as_uint()
  for _ in 0..<8 {
    if (value & 1U) != 0 {
      value = 0xEDB88320U ^ (value >> 1)
    } else {
      value = value >> 1
    }
  }
  value
}

///|
/// Wraps bytes in a zlib stream using stored (uncompressed) deflate blocks.
///
/// Deflate allows a block with no compression at all: a header, a two-byte
/// length, the length's complement and the raw bytes. That is larger than the
/// input but it is a complete, valid zlib stream, and a PNG reader has to accept
/// it. Compressing would need a match finder and a Huffman coder for a frame that
/// is a few hundred kilobytes.
fn zlib_stored(data : Bytes) -> Bytes {
  let out = Buffer::Buffer(size_hint=data.length() + 16)
  // The zlib header: deflate, 32 KiB window, no preset dictionary, and a check
  // value chosen so that the two header bytes form a multiple of 31.
  out.write_byte(b'\x78')
  out.write_byte(b'\x01')
  let mut offset = 0
  // A stored block holds at most 65535 bytes, so a frame needs several.
  while offset < data.length() || data.length() == 0 {
    let remaining = data.length() - offset
    let take = if remaining > 65535 { 65535 } else { remaining }
    let last = if offset + take >= data.length() { 1 } else { 0 }
    out.write_byte(last.reinterpret_as_uint().to_byte())
    let length = take.reinterpret_as_uint() & 0xFFFFU
    let complement = (length ^ 0xFFFFU) & 0xFFFFU
    out.write_byte((length & 0xFF).to_byte())
    out.write_byte(((length >> 8) & 0xFF).to_byte())
    out.write_byte((complement & 0xFF).to_byte())
    out.write_byte(((complement >> 8) & 0xFF).to_byte())
    for i in 0..<take {
      out.write_byte(data.at(offset + i))
    }
    offset = offset + take
    if last == 1 {
      break
    }
  }
  // Adler-32 of the uncompressed data, which is what a zlib stream ends with.
  write_u32(out, adler32(data))
  out.to_bytes()
}

///|
/// The Adler-32 checksum a zlib stream ends with.
fn adler32(data : Bytes) -> UInt32 {
  let mut a = 1U
  let mut b = 0U
  for i in 0..<data.length() {
    a = (a + data.at(i).to_int().reinterpret_as_uint()) % 65521U
    b = (b + a) % 65521U
  }
  (b << 16) | a
}
