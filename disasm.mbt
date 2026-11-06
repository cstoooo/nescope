// Disassembly: turning an opcode back into the text a data sheet uses.
//
// This exists because the trace output is the one place a user reads the
// emulator's output directly, and a column of `(?)` is worse than useless — it
// hides the fact that the column is even correct. The table is written out in
// full rather than derived, because it is a transcription of a published table
// and generating it from the execution table would mean the two could drift
// apart without either being wrong.
//
// Only the official 151 opcodes are named here. The undocumented ones are real
// and this emulator executes them, but they have no agreed mnemonics; leaving
// them unnamed is more honest than picking one of the several names in use.

///|
/// The addressing mode of an instruction, which is what decides how many operand
/// bytes follow and how they are written.
pub(all) enum Mode {
  Implied
  Accumulator
  Immediate
  ZeroPage
  ZeroPageX
  ZeroPageY
  Absolute
  AbsoluteX
  AbsoluteY
  Indirect
  IndexedIndirect
  IndirectIndexed
  Relative
}

///|
/// A decoded instruction: what it is called and how its operand is read.
pub(all) struct Decoded {
  mnemonic : String
  mode : Mode
}

///|
/// How many operand bytes follow the opcode for a mode.
pub fn Mode::operand_bytes(self : Mode) -> Int32 {
  match self {
    Implied | Accumulator => 0
    Immediate
    | ZeroPage
    | ZeroPageX
    | ZeroPageY
    | IndexedIndirect
    | IndirectIndexed
    | Relative => 1
    Absolute | AbsoluteX | AbsoluteY | Indirect => 2
  }
}

///|
/// Looks up an opcode in the official table.
///
/// Returns `None` for the undocumented opcodes, which this emulator executes but
/// does not name.
pub fn decode(opcode : UInt32) -> Decoded? {
  match opcode & 0xFFU {
    0x00U => Some({ mnemonic: "BRK", mode: Implied, })
    0x01U => Some({ mnemonic: "ORA", mode: IndexedIndirect, })
    0x02U => None
    0x03U => None
    0x04U => None
    0x05U => Some({ mnemonic: "ORA", mode: ZeroPage, })
    0x06U => Some({ mnemonic: "ASL", mode: ZeroPage, })
    0x07U => None
    0x08U => Some({ mnemonic: "PHP", mode: Implied, })
    0x09U => Some({ mnemonic: "ORA", mode: Immediate, })
    0x0AU => Some({ mnemonic: "ASL", mode: Accumulator, })
    0x0BU => None
    0x0CU => None
    0x0DU => Some({ mnemonic: "ORA", mode: Absolute, })
    0x0EU => Some({ mnemonic: "ASL", mode: Absolute, })
    0x0FU => None
    0x10U => Some({ mnemonic: "BPL", mode: Relative, })
    0x11U => Some({ mnemonic: "ORA", mode: IndirectIndexed, })
    0x12U => None
    0x13U => None
    0x14U => None
    0x15U => Some({ mnemonic: "ORA", mode: ZeroPageX, })
    0x16U => Some({ mnemonic: "ASL", mode: ZeroPageX, })
    0x17U => None
    0x18U => Some({ mnemonic: "CLC", mode: Implied, })
    0x19U => Some({ mnemonic: "ORA", mode: AbsoluteY, })
    0x1AU => None
    0x1BU => None
    0x1CU => None
    0x1DU => Some({ mnemonic: "ORA", mode: AbsoluteX, })
    0x1EU => Some({ mnemonic: "ASL", mode: AbsoluteX, })
    0x1FU => None
    0x20U => Some({ mnemonic: "JSR", mode: Absolute, })
    0x21U => Some({ mnemonic: "AND", mode: IndexedIndirect, })
    0x22U => None
    0x23U => None
    0x24U => Some({ mnemonic: "BIT", mode: ZeroPage, })
    0x25U => Some({ mnemonic: "AND", mode: ZeroPage, })
    0x26U => Some({ mnemonic: "ROL", mode: ZeroPage, })
    0x27U => None
    0x28U => Some({ mnemonic: "PLP", mode: Implied, })
    0x29U => Some({ mnemonic: "AND", mode: Immediate, })
    0x2AU => Some({ mnemonic: "ROL", mode: Accumulator, })
    0x2BU => None
    0x2CU => Some({ mnemonic: "BIT", mode: Absolute, })
    0x2DU => Some({ mnemonic: "AND", mode: Absolute, })
    0x2EU => Some({ mnemonic: "ROL", mode: Absolute, })
    0x2FU => None
    0x30U => Some({ mnemonic: "BMI", mode: Relative, })
    0x31U => Some({ mnemonic: "AND", mode: IndirectIndexed, })
    0x32U => None
    0x33U => None
    0x34U => None
    0x35U => Some({ mnemonic: "AND", mode: ZeroPageX, })
    0x36U => Some({ mnemonic: "ROL", mode: ZeroPageX, })
    0x37U => None
    0x38U => Some({ mnemonic: "SEC", mode: Implied, })
    0x39U => Some({ mnemonic: "AND", mode: AbsoluteY, })
    0x3AU => None
    0x3BU => None
    0x3CU => None
    0x3DU => Some({ mnemonic: "AND", mode: AbsoluteX, })
    0x3EU => Some({ mnemonic: "ROL", mode: AbsoluteX, })
    0x3FU => None
    0x40U => Some({ mnemonic: "RTI", mode: Implied, })
    0x41U => Some({ mnemonic: "EOR", mode: IndexedIndirect, })
    0x42U => None
    0x43U => None
    0x44U => None
    0x45U => Some({ mnemonic: "EOR", mode: ZeroPage, })
    0x46U => Some({ mnemonic: "LSR", mode: ZeroPage, })
    0x47U => None
    0x48U => Some({ mnemonic: "PHA", mode: Implied, })
    0x49U => Some({ mnemonic: "EOR", mode: Immediate, })
    0x4AU => Some({ mnemonic: "LSR", mode: Accumulator, })
    0x4BU => None
    0x4CU => Some({ mnemonic: "JMP", mode: Absolute, })
    0x4DU => Some({ mnemonic: "EOR", mode: Absolute, })
    0x4EU => Some({ mnemonic: "LSR", mode: Absolute, })
    0x4FU => None
    0x50U => Some({ mnemonic: "BVC", mode: Relative, })
    0x51U => Some({ mnemonic: "EOR", mode: IndirectIndexed, })
    0x52U => None
    0x53U => None
    0x54U => None
    0x55U => Some({ mnemonic: "EOR", mode: ZeroPageX, })
    0x56U => Some({ mnemonic: "LSR", mode: ZeroPageX, })
    0x57U => None
    0x58U => Some({ mnemonic: "CLI", mode: Implied, })
    0x59U => Some({ mnemonic: "EOR", mode: AbsoluteY, })
    0x5AU => None
    0x5BU => None
    0x5CU => None
    0x5DU => Some({ mnemonic: "EOR", mode: AbsoluteX, })
    0x5EU => Some({ mnemonic: "LSR", mode: AbsoluteX, })
    0x5FU => None
    0x60U => Some({ mnemonic: "RTS", mode: Implied, })
    0x61U => Some({ mnemonic: "ADC", mode: IndexedIndirect, })
    0x62U => None
    0x63U => None
    0x64U => None
    0x65U => Some({ mnemonic: "ADC", mode: ZeroPage, })
    0x66U => Some({ mnemonic: "ROR", mode: ZeroPage, })
    0x67U => None
    0x68U => Some({ mnemonic: "PLA", mode: Implied, })
    0x69U => Some({ mnemonic: "ADC", mode: Immediate, })
    0x6AU => Some({ mnemonic: "ROR", mode: Accumulator, })
    0x6BU => None
    0x6CU => Some({ mnemonic: "JMP", mode: Indirect, })
    0x6DU => Some({ mnemonic: "ADC", mode: Absolute, })
    0x6EU => Some({ mnemonic: "ROR", mode: Absolute, })
    0x6FU => None
    0x70U => Some({ mnemonic: "BVS", mode: Relative, })
    0x71U => Some({ mnemonic: "ADC", mode: IndirectIndexed, })
    0x72U => None
    0x73U => None
    0x74U => None
    0x75U => Some({ mnemonic: "ADC", mode: ZeroPageX, })
    0x76U => Some({ mnemonic: "ROR", mode: ZeroPageX, })
    0x77U => None
    0x78U => Some({ mnemonic: "SEI", mode: Implied, })
    0x79U => Some({ mnemonic: "ADC", mode: AbsoluteY, })
    0x7AU => None
    0x7BU => None
    0x7CU => None
    0x7DU => Some({ mnemonic: "ADC", mode: AbsoluteX, })
    0x7EU => Some({ mnemonic: "ROR", mode: AbsoluteX, })
    0x7FU => None
    0x80U => None
    0x81U => Some({ mnemonic: "STA", mode: IndexedIndirect, })
    0x82U => None
    0x83U => None
    0x84U => Some({ mnemonic: "STY", mode: ZeroPage, })
    0x85U => Some({ mnemonic: "STA", mode: ZeroPage, })
    0x86U => Some({ mnemonic: "STX", mode: ZeroPage, })
    0x87U => None
    0x88U => Some({ mnemonic: "DEY", mode: Implied, })
    0x89U => None
    0x8AU => Some({ mnemonic: "TXA", mode: Implied, })
    0x8BU => None
    0x8CU => Some({ mnemonic: "STY", mode: Absolute, })
    0x8DU => Some({ mnemonic: "STA", mode: Absolute, })
    0x8EU => Some({ mnemonic: "STX", mode: Absolute, })
    0x8FU => None
    0x90U => Some({ mnemonic: "BCC", mode: Relative, })
    0x91U => Some({ mnemonic: "STA", mode: IndirectIndexed, })
    0x92U => None
    0x93U => None
    0x94U => Some({ mnemonic: "STY", mode: ZeroPageX, })
    0x95U => Some({ mnemonic: "STA", mode: ZeroPageX, })
    0x96U => Some({ mnemonic: "STX", mode: ZeroPageY, })
    0x97U => None
    0x98U => Some({ mnemonic: "TYA", mode: Implied, })
    0x99U => Some({ mnemonic: "STA", mode: AbsoluteY, })
    0x9AU => Some({ mnemonic: "TXS", mode: Implied, })
    0x9BU => None
    0x9CU => None
    0x9DU => Some({ mnemonic: "STA", mode: AbsoluteX, })
    0x9EU => None
    0x9FU => None
    0xA0U => Some({ mnemonic: "LDY", mode: Immediate, })
    0xA1U => Some({ mnemonic: "LDA", mode: IndexedIndirect, })
    0xA2U => Some({ mnemonic: "LDX", mode: Immediate, })
    0xA3U => None
    0xA4U => Some({ mnemonic: "LDY", mode: ZeroPage, })
    0xA5U => Some({ mnemonic: "LDA", mode: ZeroPage, })
    0xA6U => Some({ mnemonic: "LDX", mode: ZeroPage, })
    0xA7U => None
    0xA8U => Some({ mnemonic: "TAY", mode: Implied, })
    0xA9U => Some({ mnemonic: "LDA", mode: Immediate, })
    0xAAU => Some({ mnemonic: "TAX", mode: Implied, })
    0xABU => None
    0xACU => Some({ mnemonic: "LDY", mode: Absolute, })
    0xADU => Some({ mnemonic: "LDA", mode: Absolute, })
    0xAEU => Some({ mnemonic: "LDX", mode: Absolute, })
    0xAFU => None
    0xB0U => Some({ mnemonic: "BCS", mode: Relative, })
    0xB1U => Some({ mnemonic: "LDA", mode: IndirectIndexed, })
    0xB2U => None
    0xB3U => None
    0xB4U => Some({ mnemonic: "LDY", mode: ZeroPageX, })
    0xB5U => Some({ mnemonic: "LDA", mode: ZeroPageX, })
    0xB6U => Some({ mnemonic: "LDX", mode: ZeroPageY, })
    0xB7U => None
    0xB8U => Some({ mnemonic: "CLV", mode: Implied, })
    0xB9U => Some({ mnemonic: "LDA", mode: AbsoluteY, })
    0xBAU => Some({ mnemonic: "TSX", mode: Implied, })
    0xBBU => None
    0xBCU => Some({ mnemonic: "LDY", mode: AbsoluteX, })
    0xBDU => Some({ mnemonic: "LDA", mode: AbsoluteX, })
    0xBEU => Some({ mnemonic: "LDX", mode: AbsoluteY, })
    0xBFU => None
    0xC0U => Some({ mnemonic: "CPY", mode: Immediate, })
    0xC1U => Some({ mnemonic: "CMP", mode: IndexedIndirect, })
    0xC2U => None
    0xC3U => None
    0xC4U => Some({ mnemonic: "CPY", mode: ZeroPage, })
    0xC5U => Some({ mnemonic: "CMP", mode: ZeroPage, })
    0xC6U => Some({ mnemonic: "DEC", mode: ZeroPage, })
    0xC7U => None
    0xC8U => Some({ mnemonic: "INY", mode: Implied, })
    0xC9U => Some({ mnemonic: "CMP", mode: Immediate, })
    0xCAU => Some({ mnemonic: "DEX", mode: Implied, })
    0xCBU => None
    0xCCU => Some({ mnemonic: "CPY", mode: Absolute, })
    0xCDU => Some({ mnemonic: "CMP", mode: Absolute, })
    0xCEU => Some({ mnemonic: "DEC", mode: Absolute, })
    0xCFU => None
    0xD0U => Some({ mnemonic: "BNE", mode: Relative, })
    0xD1U => Some({ mnemonic: "CMP", mode: IndirectIndexed, })
    0xD2U => None
    0xD3U => None
    0xD4U => None
    0xD5U => Some({ mnemonic: "CMP", mode: ZeroPageX, })
    0xD6U => Some({ mnemonic: "DEC", mode: ZeroPageX, })
    0xD7U => None
    0xD8U => Some({ mnemonic: "CLD", mode: Implied, })
    0xD9U => Some({ mnemonic: "CMP", mode: AbsoluteY, })
    0xDAU => None
    0xDBU => None
    0xDCU => None
    0xDDU => Some({ mnemonic: "CMP", mode: AbsoluteX, })
    0xDEU => Some({ mnemonic: "DEC", mode: AbsoluteX, })
    0xDFU => None
    0xE0U => Some({ mnemonic: "CPX", mode: Immediate, })
    0xE1U => Some({ mnemonic: "SBC", mode: IndexedIndirect, })
    0xE2U => None
    0xE3U => None
    0xE4U => Some({ mnemonic: "CPX", mode: ZeroPage, })
    0xE5U => Some({ mnemonic: "SBC", mode: ZeroPage, })
    0xE6U => Some({ mnemonic: "INC", mode: ZeroPage, })
    0xE7U => None
    0xE8U => Some({ mnemonic: "INX", mode: Implied, })
    0xE9U => Some({ mnemonic: "SBC", mode: Immediate, })
    0xEAU => Some({ mnemonic: "NOP", mode: Implied, })
    0xEBU => None
    0xECU => Some({ mnemonic: "CPX", mode: Absolute, })
    0xEDU => Some({ mnemonic: "SBC", mode: Absolute, })
    0xEEU => Some({ mnemonic: "INC", mode: Absolute, })
    0xEFU => None
    0xF0U => Some({ mnemonic: "BEQ", mode: Relative, })
    0xF1U => Some({ mnemonic: "SBC", mode: IndirectIndexed, })
    0xF2U => None
    0xF3U => None
    0xF4U => None
    0xF5U => Some({ mnemonic: "SBC", mode: ZeroPageX, })
    0xF6U => Some({ mnemonic: "INC", mode: ZeroPageX, })
    0xF7U => None
    0xF8U => Some({ mnemonic: "SED", mode: Implied, })
    0xF9U => Some({ mnemonic: "SBC", mode: AbsoluteY, })
    0xFAU => None
    0xFBU => None
    0xFCU => None
    0xFDU => Some({ mnemonic: "SBC", mode: AbsoluteX, })
    0xFEU => Some({ mnemonic: "INC", mode: AbsoluteX, })
    0xFFU => None
    _ => None
  }
}

///|
/// Renders a decoded instruction as text, given its operand bytes.
///
/// The layout follows the convention the reference logs use: a bare mnemonic for
/// implied and accumulator modes, `#$xx` for immediate, `$xx` for zero page and
/// `$xxxx` for absolute, with `,X` and `,Y` appended where the mode indexes. The
/// parentheses around indirect modes are what distinguish `($20),Y` from `$20,Y`,
/// and getting them wrong makes a disassembly that reads plausibly and is wrong.
pub fn render(decoded : Decoded, operand : UInt32) -> String {
  let low = operand & 0xFF
  match decoded.mode {
    Implied => decoded.mnemonic
    // The accumulator form is spelled out because `ASL` alone is ambiguous with
    // the implied form, and the reference logs write it as `ASL A`.
    Accumulator => decoded.mnemonic + " A"
    Immediate => decoded.mnemonic + " #$" + hex_byte(low)
    ZeroPage => decoded.mnemonic + " $" + hex_byte(low)
    ZeroPageX => decoded.mnemonic + " $" + hex_byte(low) + ",X"
    ZeroPageY => decoded.mnemonic + " $" + hex_byte(low) + ",Y"
    Absolute => decoded.mnemonic + " $" + hex_word(operand)
    AbsoluteX => decoded.mnemonic + " $" + hex_word(operand) + ",X"
    AbsoluteY => decoded.mnemonic + " $" + hex_word(operand) + ",Y"
    Indirect => decoded.mnemonic + " ($" + hex_word(operand) + ")"
    IndexedIndirect => decoded.mnemonic + " ($" + hex_byte(low) + ",X)"
    IndirectIndexed => decoded.mnemonic + " ($" + hex_byte(low) + "),Y"
    // A branch operand is a signed displacement from the byte after the
    // instruction, so the rendered text is an absolute address rather than the
    // raw offset. Showing the offset would be technically honest and useless to
    // anyone comparing against a log.
    Relative => decoded.mnemonic + " $" + hex_word(operand)
  }
}

///|
/// Two uppercase hex digits, matching the convention every 6502 reference log
/// uses. Lowercase would be readable and would make a diff against a reference
/// trace look like a state difference rather than a formatting one.
fn hex_byte(value : UInt32) -> String {
  let text = (value & 0xFF).to_string(radix=16).to_upper()
  if text.length() >= 2 {
    text
  } else {
    "0" + text
  }
}

///|
/// Four lowercase hex digits.
fn hex_word(value : UInt32) -> String {
  let text = (value & 0xFFFF).to_string(radix=16).to_upper()
  let mut padded = text
  while padded.length() < 4 {
    padded = "0" + padded
  }
  padded
}
