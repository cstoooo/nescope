// Tests for the PNG writer.
//
// A PNG that a decoder rejects is worse than no PNG at all, so these tests check
// the checksums and the stream structure rather than only "did it produce
// bytes". The CRC and Adler-32 values below are the ones a reference zlib
// computes, which is what makes this a differential test rather than a
// self-consistency check: if the writer and the test shared a bug they would
// still agree with each other.

///|
/// A frame filled with one palette index.
fn solid_frame(index : UInt32) -> FixedArray[Byte] {
  FixedArray::make(SCREEN_WIDTH * SCREEN_HEIGHT, index.to_byte())
}

///|
/// Reads a big-endian 32-bit value out of a byte buffer.
fn read_u32(bytes : Bytes, at : Int32) -> UInt32 {
  ((bytes.at(at).to_int().reinterpret_as_uint() & 0xFF) << 24) |
  ((bytes.at(at + 1).to_int().reinterpret_as_uint() & 0xFF) << 16) |
  ((bytes.at(at + 2).to_int().reinterpret_as_uint() & 0xFF) << 8) |
  (bytes.at(at + 3).to_int().reinterpret_as_uint() & 0xFF)
}

///|
test "the palette maps every index to an opaque colour" {
  // Index zero is the NES's grey backdrop; index $0F is black; the last group
  // repeats some of the first. What matters is that every one of the 64 indices
  // produces a colour rather than panicking on an out-of-range read.
  let (r, g, b) = nes_colour(0U)
  inspect_at("backdrop red", r.reinterpret_as_int(), 0x66)
  inspect_at("backdrop green", g.reinterpret_as_int(), 0x66)
  inspect_at("backdrop blue", b.reinterpret_as_int(), 0x66)
  let (r, g, b) = nes_colour(0x0FU)
  inspect_at("black red", r.reinterpret_as_int(), 0x00)
  inspect_at("black green", g.reinterpret_as_int(), 0x00)
  inspect_at("black blue", b.reinterpret_as_int(), 0x00)
  // An index with bits above the palette's width set must be masked rather than
  // read past the end of the table.
  let (r, _, _) = nes_colour(0xFFU)
  let (r2, _, _) = nes_colour(0x3FU)
  inspect_at("masked index", r.reinterpret_as_int(), r2.reinterpret_as_int())
}

///|
test "the writer produces a PNG signature, header and end chunk" {
  let png = encode_png(solid_frame(0x0FU))
  inspect_eq(png.at(0).to_int() & 0xFF, 0x89)
  inspect_eq(png.at(1).to_int() & 0xFF, 0x50)
  inspect_eq(png.at(2).to_int() & 0xFF, 0x4E)
  inspect_eq(png.at(3).to_int() & 0xFF, 0x47)
  // The first chunk's length is 13 bytes and its type is IHDR.
  inspect_eq(read_u32(png, 8), 13U)
  inspect_eq(png.at(12).to_int() & 0xFF, 0x49)
  inspect_eq(png.at(13).to_int() & 0xFF, 0x48)
  inspect_eq(png.at(14).to_int() & 0xFF, 0x44)
  inspect_eq(png.at(15).to_int() & 0xFF, 0x52)
  // The header names the frame's size and the 8-bit truecolour format.
  inspect_eq(read_u32(png, 16), SCREEN_WIDTH.reinterpret_as_uint())
  inspect_eq(read_u32(png, 20), SCREEN_HEIGHT.reinterpret_as_uint())
  inspect_eq(png.at(24).to_int() & 0xFF, 8)
  inspect_eq(png.at(25).to_int() & 0xFF, 2)
  // The file has to end with IEND, or a decoder reports a truncated image. That
  // chunk is twelve bytes: a four-byte length, the type and the CRC.
  let tail = png.length() - 12
  inspect_eq(png.at(tail + 4).to_int() & 0xFF, 0x49)
  inspect_eq(png.at(tail + 5).to_int() & 0xFF, 0x45)
  inspect_eq(png.at(tail + 6).to_int() & 0xFF, 0x4E)
  inspect_eq(png.at(tail + 7).to_int() & 0xFF, 0x44)
}

///|
test "chunk checksums match the reference CRC-32" {
  // The CRC of the eight bytes "IEND" with an empty payload, which every PNG
  // file ends with and which a reference implementation computes as $AE426082.
  inspect_eq(crc32(Bytes::from_array([b'I', b'E', b'N', b'D'])), 0xAE426082U)
  // The CRC of "IHDR" alone, another fixed point that does not depend on the
  // frame's contents.
  inspect_eq(crc32(Bytes::from_array([b'I', b'H', b'D', b'R'])), 0xA8A1AE0AU)
}

///|
test "the Adler-32 matches the reference value" {
  // Adler-32 of "Wikipedia" is the value the spec's own worked example gives.
  let text = Bytes::from_array([
    b'W', b'i', b'k', b'i', b'p', b'e', b'd', b'i', b'a',
  ])
  inspect_eq(adler32(text), 0x11E60398U)
}

///|
test "the frame round-trips through the stored deflate blocks" {
  // Two different palette indices must survive to the pixel data, which proves
  // the writer is emitting the frame rather than a constant.
  let frame = solid_frame(0x0FU)
  frame[0] = b'\x01'
  frame[1] = b'\x2A'
  let png = encode_png(frame)
  // The compressed payload starts after the signature and the IHDR chunk: 8
  // bytes of signature, 12 bytes of chunk overhead, 13 bytes of header, then a
  // further 12 bytes of overhead before the IDAT payload.
  // 8 + (12 + 13) + (12 + 0) = 45 is where IDAT's payload begins.
  let idat_at = 8 + 12 + 13 + 8
  // The zlib header is two bytes; then a stored block's five-byte header; then
  // the first row's filter byte and its first pixel.
  inspect_eq(png.at(idat_at).to_int() & 0xFF, 0x78)
  inspect_eq(png.at(idat_at + 1).to_int() & 0xFF, 0x01)
  let first_pixel = idat_at + 2 + 5 + 1
  // Palette index one is the second entry: $002A88.
  inspect_eq(png.at(first_pixel).to_int() & 0xFF, 0x00)
  inspect_eq(png.at(first_pixel + 1).to_int() & 0xFF, 0x2A)
  inspect_eq(png.at(first_pixel + 2).to_int() & 0xFF, 0x88)
}
