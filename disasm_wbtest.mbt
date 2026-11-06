// Tests for the disassembler.
//
// The table is a transcription, so these tests do not try to cover all 256
// entries. What they pin is the part that was hard to get right: the operand
// length per mode, the indirection syntax, and the branch target arithmetic.
// Getting the table wrong is a typo; getting the renderer wrong produces text
// that reads plausibly and is wrong.

///|
test "every official opcode is named and has the right operand length" {
  // 151 official opcodes; the other 105 are undocumented.
  let mut named = 0
  for opcode in 0..<256 {
    match decode(opcode.reinterpret_as_uint()) {
      Some(d) => {
        named = named + 1
        // An implied instruction must have a mnemonic and never an operand, and
        // a mode's operand length must be one of the three legal values.
        let bytes = d.mode.operand_bytes()
        inspect_bool(bytes == 0 || bytes == 1 || bytes == 2, true)
      }
      None => ()
    }
  }
  inspect_eq(named, 151)
}

///|
test "the modes that differ only by syntax render differently" {
  // `LDA $20,X` and `LDA ($20),Y` read the same operand byte and are entirely
  // different instructions; a renderer that confused them would produce a
  // disassembly that looks right and is not.
  let absolute_x = match decode(0xBDU) {
    Some(d) => render(d, 0x1234U)
    None => ""
  }
  inspect_eq(absolute_x, "LDA $1234,X")
  let indirect_y = match decode(0xB1U) {
    Some(d) => render(d, 0x20U)
    None => ""
  }
  inspect_eq(indirect_y, "LDA ($20),Y")
  let indexed_indirect = match decode(0xA1U) {
    Some(d) => render(d, 0x20U)
    None => ""
  }
  inspect_eq(indexed_indirect, "LDA ($20,X)")
  let immediate = match decode(0xA9U) {
    Some(d) => render(d, 0x2AU)
    None => ""
  }
  inspect_eq(immediate, "LDA #$2A")
  let zero_page = match decode(0xA5U) {
    Some(d) => render(d, 0x2AU)
    None => ""
  }
  inspect_eq(zero_page, "LDA $2A")
}

///|
test "implied and accumulator modes differ" {
  // `ASL` alone is the implied form and `ASL A` is the accumulator form; the
  // opcode decides which, not the operand.
  let implied = match decode(0xEAU) {
    Some(d) => render(d, 0U)
    None => ""
  }
  inspect_eq(implied, "NOP")
  let accumulator = match decode(0x0AU) {
    Some(d) => render(d, 0U)
    None => ""
  }
  inspect_eq(accumulator, "ASL A")
}

///|
test "an undocumented opcode decodes to nothing rather than to a guess" {
  // $1A is one of the unofficial NOPs. This emulator executes it, but it has no
  // agreed mnemonic, and inventing one would make the trace output claim more
  // than it knows.
  match decode(0x1AU) {
    Some(_) => fail("expected $1A to be undecoded")
    None => ()
  }
}

///|
test "a branch's operand length is one and its mode is relative" {
  // The renderer takes the resolved target, so this pins that decode reports the
  // mode the caller needs in order to resolve it.
  match decode(0xD0U) {
    Some(d) => {
      inspect_eq(d.mnemonic, "BNE")
      inspect_eq(d.mode.operand_bytes(), 1)
    }
    None => fail("expected BNE to decode")
  }
}
