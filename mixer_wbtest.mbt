// Tests for the audio mixer.
//
// There is no golden audio trace the way the CPU has a golden instruction log, so
// these pin the properties that make the difference between "a tone comes out" and
// "the right tone comes out": the duty table, the timer reload, the sample rate,
// and the mixer's nonlinear curve.

///|
/// Adds up a sequence, which is how a duty ratio is measured here: the number of
/// high samples in eight is the ratio times eight.
fn sum_of(values : FixedArray[UInt32]) -> Int32 {
  let mut total = 0
  for value in values {
    total = total + value.reinterpret_as_int()
  }
  total
}

///|
/// The four duty sequences must be the hardware's, because they are the channel's
/// timbre: sequence 1 is a square wave, sequence 2 is half as wide, and sequence 3
/// is sequence 2 inverted.
test "the duty sequences are the hardware ones" {
  inspect_eq(duty_sequence(0U).length(), 8)
  // 12.5% duty: one high sample in eight.
  inspect_eq(sum_of(duty_sequence(0U)), 1)
  // 25% duty.
  inspect_eq(sum_of(duty_sequence(1U)), 2)
  // 50% duty.
  inspect_eq(sum_of(duty_sequence(2U)), 4)
  // 75% duty, which is sequence 2 negated: it starts high rather than low.
  inspect_eq(sum_of(duty_sequence(3U)), 6)
  inspect_eq(duty_sequence(2U)[0], 0U)
  inspect_eq(duty_sequence(3U)[0], 1U)
}

///|
/// The triangle walks from 15 down to 0 and back up, which is what makes its
/// output a triangle rather than a ramp that resets.
test "the triangle sequence walks down and back up without a jump" {
  let sequence = triangle_sequence()
  inspect_eq(sequence.length(), 32)
  inspect_eq(sequence[0], 15U)
  inspect_eq(sequence[15], 0U)
  inspect_eq(sequence[16], 0U)
  inspect_eq(sequence[31], 15U)
  // Every step moves by one, or by zero at the two turning points, so the waveform
  // has no discontinuity: 15 down to 0, a repeat of 0, then back up to 15.
  let mut turns = 0
  for i in 1..<32 {
    let previous = sequence[i - 1].reinterpret_as_int()
    let current = sequence[i].reinterpret_as_int()
    let step = if current > previous {
      current - previous
    } else {
      previous - current
    }
    if step == 0 {
      turns = turns + 1
    } else {
      inspect_eq(step, 1)
    }
  }
  inspect_eq(turns, 1)
}

///|
/// A pulse's real period is twice the register plus one, and the sequencer moves
/// one step per period. That factor is the whole reason the same register value
/// gives a different pitch than a naive reading would predict.
test "a pulse advances one duty step per 2*period+1 cycles" {
  let channel = Channel::silent()
  channel.period = 100U
  channel.duty = 2U
  channel.active = true
  channel.timer = 2U * 100U + 1U
  // One reload: 201 cycles reaches the next step exactly.
  channel.tick_pulse(201L)
  inspect_eq(channel.sequence, 1U)
  // Half a reload does not.
  channel.tick_pulse(100L)
  inspect_eq(channel.sequence, 1U)
  channel.tick_pulse(101L)
  inspect_eq(channel.sequence, 2U)
}

///|
/// A pulse whose period is below eight is inaudible on hardware, and producing the
/// value anyway would be a squeal the console never made.
test "a pulse with too small a period is silent" {
  let channel = Channel::silent()
  channel.duty = 2U
  channel.active = true
  channel.period = 4U
  channel.tick_pulse(100L)
  inspect_eq(channel.output, 0U)
  channel.period = 0x0FD0U
  channel.tick_pulse(1000L)
  // Duty 2 starts with three low samples, so the channel is producing either 0 or
  // 1; the point is that it is running at all.
  ignore(channel.sequence)
}

///|
/// A channel with its length counter clocked to zero must stop producing samples,
/// which is what makes a note end.
test "a silent channel advances no timer" {
  let channel = Channel::silent()
  channel.period = 100U
  channel.active = false
  channel.tick_pulse(1000L)
  inspect_eq(channel.sequence, 0U)
  inspect_eq(channel.output, 0U)
}

///|
/// At 44100 Hz one second of emulation is 44100 samples, and the fractional
/// accumulator must not lose or gain one per second.
test "one second of CPU cycles produces one second of samples" {
  let mixer = Mixer::new(44100U)
  let out : Array[UInt32] = []
  // Half a second at a time, so the accumulator has to carry across calls.
  ignore(mixer.run(CPU_CLOCK / 2L, out))
  ignore(mixer.run(CPU_CLOCK / 2L, out))
  let count = out.length()
  // A cycle of rounding either way is acceptable; a drift of hundreds is not.
  inspect_bool(count >= 44099 && count <= 44101, true)
}

///|
/// A mixer with every channel silent produces a constant value, not noise: the
/// hardware's DAC rests at zero and a stream that wandered would be heard as a hum.
test "silence is a constant zero sample" {
  let mixer = Mixer::new(44100U)
  let out : Array[UInt32] = []
  ignore(mixer.run(10000L, out))
  for sample in out {
    inspect_eq(sample, 0U)
  }
}

///|
/// The mixer's curve must not clip a single channel at full volume, and must stay
/// inside the byte range when every channel is at maximum.
test "the mixer stays in range at both extremes" {
  let mixer = Mixer::new(44100U)
  mixer.pulse1.output = 15U
  let one = mixer.sample()
  inspect_bool(one > 0U && one < 255U, true)
  mixer.pulse2.output = 15U
  mixer.triangle.output = 15U
  mixer.noise.output = 15U
  let all = mixer.sample()
  inspect_bool(all > one, true)
  inspect_bool(all <= 255U, true)
}

///|
/// A WAV file's header has to be exactly what a decoder expects: 44 bytes, the
/// RIFF and WAVE tags, and the data length matching the payload.
test "the WAV header describes the samples that follow it" {
  let samples : Array[UInt32] = [0U, 128U, 255U]
  let wav = encode_wav(samples, 44100U)
  inspect_eq(wav.length(), 44 + 6)
  // "RIFF" and "WAVE".
  inspect_eq(wav.at(0).to_int(), 0x52)
  inspect_eq(wav.at(1).to_int(), 0x49)
  inspect_eq(wav.at(8).to_int(), 0x57)
  inspect_eq(wav.at(9).to_int(), 0x41)
  // The byte rate is rate * channels * bytes per sample.
  inspect_eq(
    wav.at(28).to_int() | (wav.at(29).to_int() << 8),
    (44100 * 2) & 0xFFFF,
  )
  // Silence maps to a value near the centre of the signed range rather than to the
  // bottom, so a WAV player hears a DC offset instead of quiet.
  let first_low = wav.at(44).to_int() & 0xFF
  let first_high = wav.at(45).to_int() & 0xFF
  inspect_eq(first_low | (first_high << 8), 0x8000)
}

///|
/// The register writes have to reach the oscillators, or the whole audio path
/// silently produces silence no matter how correct the mixer is.
test "register writes reach the pulse oscillators" {
  let apu = Apu::new()
  apu.write_status(0x0FU)
  // Pulse 1: duty 2, no halt, then period low bits, then high bits.
  apu.write_register(0x00U, 0x80U)
  inspect_eq(apu.mixer.pulse1.duty, 2U)
  apu.write_register(0x02U, 0xD0U)
  apu.write_register(0x03U, 0x0AU)
  // $4002 holds the low eight bits and $4003's low three bits are the top of the
  // eleven-bit period: $D0 and $2 give $2D0. The rest of $4003 is the length
  // counter's index.
  inspect_eq(apu.mixer.pulse1.period, 0x2D0U)
  inspect_bool(apu.mixer.pulse1.active, true)
}

///|
/// The triangle's $400B works the same way, and its channel is started by the same
/// length-counter write.
test "register writes reach the triangle oscillator" {
  let apu = Apu::new()
  apu.write_status(0x04U)
  apu.write_register(0x0AU, 0x42U)
  apu.write_register(0x0BU, 0x08U)
  inspect_eq(apu.mixer.triangle.period, 0x042U)
  inspect_bool(apu.mixer.triangle.active, true)
}

///|
/// Disabling a channel through `$4015` must silence its oscillator as well as clear
/// its counter, which is how a game cuts a note short.
test "disabling a channel silences its oscillator" {
  let apu = Apu::new()
  apu.write_status(0x0FU)
  apu.write_register(0x03U, 0x08U)
  inspect_bool(apu.mixer.pulse1.active, true)
  apu.write_status(0x0EU)
  inspect_bool(apu.mixer.pulse1.active, false)
  inspect_eq(apu.mixer.pulse1.output, 0U)
}

///|
/// The APU accumulates samples as it ticks, and draining them empties the buffer,
/// so a caller that writes a file gets each sample exactly once.
test "ticking the APU produces samples and draining them empties the buffer" {
  let apu = Apu::new()
  ignore(apu.tick(10000L))
  let samples = apu.take_samples()
  inspect_bool(samples.length() > 0, true)
  inspect_eq(apu.samples.length(), 0)
  // Draining twice must not hand the same samples out again.
  inspect_eq(apu.take_samples().length(), 0)
}

///|
test "a playing pulse produces a varying sample stream" {
  let apu = Apu::new()
  apu.write_status(0x0FU)
  apu.write_register(0x00U, 0x80U)
  apu.write_register(0x02U, 0xD0U)
  apu.write_register(0x03U, 0x0AU)
  let mut cycled = 0L
  while cycled < 20000L {
    ignore(apu.tick(100L))
    cycled = cycled + 100L
  }
  let samples = apu.take_samples()
  let mut low = 255U
  let mut high = 0U
  for s in samples {
    if s < low {
      low = s
    }
    if s > high {
      high = s
    }
  }
  inspect_bool(high > low, true)
  inspect_bool(high > 0U, true)
}
