// Turning the APU's channel state into samples.
//
// The four APU channels each produce a stream of small integers at their own
// rate, and the mixer's job is to run each channel's timer down to zero, sample
// it, and add the four results. Two details make the difference between "sound
// comes out" and "the sound is right":
//
//   * The timers count *CPU* cycles, not samples. A pulse's period register holds
//     a value whose real period is twice it plus one, and the sequencer advances
//     once per period, so the same register produces different pitches on NTSC and
//     PAL.
//   * The pulse output is a four-step sequence selected by a three-bit duty
//     value, and only sequences 0, 1 and 2 are useful: sequence 3 inverts sequence
//     2 and silences the channel on real hardware. Getting the duty table wrong
//     changes the timbre of every note, which is audible immediately.
//
// What is not modelled here: the sweep units, the envelope generators, the
// triangle's ultrasonic-silence behaviour, the DMC, and the hardware's nonlinear
// mixing curve. Those are all audibly significant, and leaving them out means a
// game's music plays at the right pitch but with a flat, unchanging volume.

///|
/// The four step duty sequences a pulse channel can select.
///
/// Each is eight samples of a square wave with a different mark-to-space ratio, so
/// the four settings sound like 12.5%, 25%, 50% and 75% duty. The fourth is the
/// 75% one *negated*, which makes it identical to the second shifted by a quarter
/// of a cycle; real hardware mutes that setting by ANDing it with the result, and
/// the inversion is kept here so the muted case stays visibly a choice.
fn duty_sequence(duty : UInt32) -> FixedArray[UInt32] {
  let table : FixedArray[FixedArray[UInt32]] = [
    [0U, 1U, 0U, 0U, 0U, 0U, 0U, 0U],
    [0U, 1U, 1U, 0U, 0U, 0U, 0U, 0U],
    [0U, 1U, 1U, 1U, 1U, 0U, 0U, 0U],
    [1U, 0U, 0U, 1U, 1U, 1U, 1U, 1U],
  ]
  table[(duty & 0x03).reinterpret_as_int()]
}

///|
/// The triangle's step sequence: sixteen entries that walk up and down, which is
/// what makes its output a triangle rather than a square.
fn triangle_sequence() -> FixedArray[UInt32] {
  [
    15U, 14U, 13U, 12U, 11U, 10U, 9U, 8U, 7U, 6U, 5U, 4U, 3U, 2U, 1U, 0U, 0U, 1U,
    2U, 3U, 4U, 5U, 6U, 7U, 8U, 9U, 10U, 11U, 12U, 13U, 14U, 15U,
  ]
}

///|
/// One channel's oscillator state.
pub(all) struct Channel {
  /// The eleven-bit period register, as written.
  mut period : UInt32
  /// Down-counter; decremented once per CPU cycle and reloaded from the period
  /// when it reaches zero.
  mut timer : UInt32
  /// Position in the duty or triangle sequence.
  mut sequence : UInt32
  /// The duty bits for a pulse, or the control flag for a triangle.
  mut duty : UInt32
  /// True while the channel is producing anything at all. A pulse whose length
  /// counter has run out is silent; a triangle keeps running and only rests.
  mut active : Bool
  /// The channel's current output, 0 to 15.
  mut output : UInt32
}

///|
/// A silent channel.
fn Channel::silent() -> Channel {
  { period: 0U, timer: 0U, sequence: 0U, duty: 0U, active: false, output: 0U, }
}

///|
/// Four channels mixed into one stream of samples.
pub(all) struct Mixer {
  /// The two pulse channels.
  pulse1 : Channel
  pulse2 : Channel
  triangle : Channel
  noise : Channel
  /// The sample rate the output is produced at, in hertz.
  rate : UInt32
  /// CPU cycles accumulated toward the next sample.
  mut accumulator : Int64
  /// How many CPU cycles one output sample spans, as a fixed-point number with
  /// sixteen fractional bits. Kept fractional because 44100 samples per second
  /// and 1789773 CPU cycles per second do not divide.
  mut step : Int64
}

///|
/// The NTSC CPU clock, which is what every channel timer counts.
pub const CPU_CLOCK : Int64 = 1789773L

///|
/// A mixer producing `rate` samples per second.
pub fn Mixer::new(rate : UInt32) -> Mixer {
  let rate = if rate == 0U { 44100U } else { rate }
  {
    pulse1: Channel::silent(),
    pulse2: Channel::silent(),
    triangle: Channel::silent(),
    noise: Channel::silent(),
    rate,
    accumulator: 0L,
    step: (CPU_CLOCK << 16) / rate.reinterpret_as_int().to_int64(),
  }
}

///|
/// Advances one pulse channel by `cycles` CPU cycles.
///
/// The timer reloads from `2 * period + 1` rather than from the period: the
/// hardware adds one cycle so that odd periods are reachable at all, and the
/// sequencer's eight steps then divide that by eight to give the pitch.
fn Channel::tick_pulse(self : Channel, cycles : Int64) -> Unit {
  if !self.active {
    return
  }
  let reload = self.period * 2U + 1U
  let mut left = cycles
  while left > 0L {
    // Jump straight to the next reload unless the reload is longer than what is
    // left, which keeps a high period from costing thousands of loop iterations.
    // A timer holding `t` reaches zero after exactly `t` cycles, so the boundary
    // is `left >= timer`: `t` cycles advance the sequence by one step, not by zero.
    let timer = self.timer.reinterpret_as_int().to_int64()
    if left >= timer {
      left = left - timer
      self.timer = reload
      self.sequence = (self.sequence + 1U) & 0x07U
    } else {
      self.timer = (timer - left).to_int().reinterpret_as_uint()
      left = 0L
    }
  }
  // A pulse with period below eight is inaudible on hardware because the output
  // is muted when the period is too small to complete a cycle. Producing the
  // value anyway would be a high-frequency squeal the console never made.
  if self.period < 8U || reload > 0x7FFU {
    self.output = 0U
    return
  }
  self.output = duty_sequence(self.duty)[self.sequence.reinterpret_as_int()]
}

///|
/// Advances the triangle by `cycles` CPU cycles.
///
/// The triangle is a linear counter rather than a length counter: it steps through
/// its sixteen-entry sequence once per timer reload and never stops at a value the
/// way a pulse does. A period below two silences it, which the hardware does
/// deliberately because the frequency would be above the audible range.
fn Channel::tick_triangle(self : Channel, cycles : Int64) -> Unit {
  if !self.active {
    return
  }
  let reload = self.period + 1U
  let mut left = cycles
  while left > 0L {
    let timer = self.timer.reinterpret_as_int().to_int64()
    if left >= timer {
      left = left - timer
      self.timer = reload
      self.sequence = (self.sequence + 1U) & 0x1FU
    } else {
      self.timer = (timer - left).to_int().reinterpret_as_uint()
      left = 0L
    }
  }
  if self.period < 2U {
    self.output = 0U
    return
  }
  // The low bit of the control register holds the sequencer at one point, which
  // a game uses to mute the channel without disabling it.
  if (self.duty & 0x01U) == 0U {
    self.output = triangle_sequence()[self.sequence.reinterpret_as_int()]
  }
}

///|
/// Advances one mixer sample's worth of channels.
fn Mixer::clock(self : Mixer, cycles : Int64) -> Unit {
  self.pulse1.tick_pulse(cycles)
  self.pulse2.tick_pulse(cycles)
  self.triangle.tick_triangle(cycles)
  // The noise channel has no tonal state worth modelling: its output is a
  // pseudo-random bit stream whose volume is the only audible property, and its
  // timer feeding a shift register is what makes the difference between the two
  // "metallic" modes. Left silent until that register is modelled.
  self.noise.output = 0U
}

///|
/// Mixes the channels into one sample, in the range 0 to 255.
///
/// The hardware's mixer is nonlinear, and the curve is not a detail: each channel
/// passes through a compressing function before the results are added, so four
/// channels at full volume stay inside range instead of clipping. A linear sum is
/// the common approximation and it sounds wrong in a specific way — the loudest
/// passage of a piece distorts while the quiet part is too quiet.
///
/// The two stages are separate because the pulses share one DAC and the triangle
/// and noise share another. The constants are the ones measured from the
/// hardware; they take the pulse sum (0 to 30) and the triangle-plus-noise sum
/// (0 to 31) and produce 0.0 to 1.0 each.
fn Mixer::sample(self : Mixer) -> UInt32 {
  let pulse_sum = self.pulse1.output + self.pulse2.output
  let tnd_sum = self.triangle.output * 2U + self.noise.output * 2U
  let pulse = if pulse_sum == 0U {
    0.0
  } else {
    95.88 / (8128.0 / pulse_sum.to_double() + 100.0)
  }
  let tnd = if tnd_sum == 0U {
    0.0
  } else {
    159.79 / (1.0 / (tnd_sum.to_double() / 8227.0) + 100.0)
  }
  // The sum of the two stages is 0.0 to 1.0; scaling by 255 lands it in the byte
  // range the rest of the pipeline assumes. The clamp is not redundant: a channel
  // output that a bug pushed past its range would otherwise wrap and be heard as
  // a click rather than as a loud passage.
  let scaled = ((pulse + tnd) * 255.0).to_int()
  if scaled < 0 {
    0U
  } else if scaled > 255 {
    255U
  } else {
    scaled.reinterpret_as_uint()
  }
}

///|
/// Runs the channels for `cycles` CPU cycles and appends each sample that falls in
/// that span, so a caller can drive the mixer from the emulator's own cycle count
/// rather than from a wall clock.
///
/// Returns the number of samples appended.
pub fn Mixer::run(self : Mixer, cycles : Int64, out : Array[UInt32]) -> Int32 {
  let mut written = 0
  // The accumulator holds fractional CPU cycles, so a sample boundary falls
  // wherever it falls rather than being rounded to a whole cycle. Rounding would
  // drift by a sample every few seconds.
  self.accumulator = self.accumulator + cycles * 65536L
  while self.accumulator >= self.step {
    self.accumulator = self.accumulator - self.step
    // Each sample covers one step's worth of cycles, so the channels advance by
    // that much between samples. Advancing by the whole instruction's cycles and
    // then sampling once would alias every note above a few hundred hertz.
    let per_sample = self.step / 65536L
    self.clock(per_sample)
    out.push(self.sample())
    written = written + 1
  }
  written
}

///|
/// A mono 16-bit PCM WAV file: a 44-byte header followed by little-endian samples.
///
/// The samples are scaled from the mixer's 0-to-255 range to the signed 16-bit
/// range and centred on zero, because a WAV player treats silence as zero and an
/// unsigned 8-bit stream would be heard as a DC offset.
pub fn encode_wav(samples : Array[UInt32], rate : UInt32) -> Bytes {
  let out = Buffer::Buffer(size_hint=44 + samples.length() * 2)
  let data_length = samples.length() * 2
  write_ascii(out, "RIFF")
  write_le_u32(out, (36 + data_length).reinterpret_as_uint())
  write_ascii(out, "WAVE")
  write_ascii(out, "fmt ")
  write_le_u32(out, 16U)
  // Format 1 is uncompressed PCM.
  write_le_u16(out, 1U)
  write_le_u16(out, 1U)
  write_le_u32(out, rate)
  // Byte rate: rate * channels * bytes per sample.
  write_le_u32(out, rate * 2U)
  write_le_u16(out, 2U)
  write_le_u16(out, 16U)
  write_ascii(out, "data")
  write_le_u32(out, data_length.reinterpret_as_uint())
  for sample in samples {
    // Centre the unsigned value on zero before scaling: 0 maps to -32768 and 255
    // to +32768, which is the full range.
    let centred = sample.reinterpret_as_int() * 257 - 32768
    write_le_u16(out, (centred & 0xFFFF).reinterpret_as_uint())
  }
  out.to_bytes()
}

///|
/// Appends four ASCII bytes.
fn write_ascii(out : Buffer, text : String) -> Unit {
  for i in 0..<text.length() {
    out.write_byte(text.code_unit_at(i).to_byte())
  }
}

///|
/// Appends a 32-bit little-endian value.
fn write_le_u32(out : Buffer, value : UInt32) -> Unit {
  out.write_byte((value & 0xFF).to_byte())
  out.write_byte(((value >> 8) & 0xFF).to_byte())
  out.write_byte(((value >> 16) & 0xFF).to_byte())
  out.write_byte(((value >> 24) & 0xFF).to_byte())
}

///|
/// Appends a 16-bit little-endian value.
fn write_le_u16(out : Buffer, value : UInt32) -> Unit {
  out.write_byte((value & 0xFF).to_byte())
  out.write_byte(((value >> 8) & 0xFF).to_byte())
}
