## The Minecraft wire format's primitives, and nothing else.
##
## No host call, no socket, no Unity. Bytes in, values out; values in, bytes
## out. Everything here is the *encoding*, which is why it is a separate file
## from the framing above it and the packets above that: a decoder that can be
## proved against hand-written byte vectors is a decoder that never needs a
## server to be tested, and that is the whole reason this mod could be built
## before any of the transport question was settled.
##
## Target: **protocol 774**, the wire the 1.21.11 client speaks. Every rule in
## here has been the same since 1.16 except `Position`, whose field order
## changed in 1.14 and is noted where it is decoded.
##
## THE THREE FACTS ABOUT THIS INTERPRETER'S INTEGERS that everything here
## depends on, each of which was measured rather than assumed, and each of
## which is asserted again in `Tests/mcnet_test.nim`:
##
## 1. `int` is 64 bits and `shr` on it is **arithmetic**: `-1 shr 1` is `-1`,
##    not a huge positive. So every extraction that could see a negative word
##    masks after shifting, never before.
## 2. `shl` **wraps silently** - `1 shl 63` is the smallest int64 and
##    `0xFFFFFFFF shl 32` is `-4294967296`. It does not raise the way `*` does.
##    That is what lets a big-endian long be assembled in one expression, and
##    what makes the tenth byte of a VarLong behave exactly as Java's
##    `value |= (b & 0x7F) << 63` does.
## 3. `cast[int64]`/`cast[float64]` are available and are a bit
##    reinterpretation, which is how the IEEE-754 scalars are read without
##    arithmetic.
##
## Nothing here raises. A malformed or short input sets `problem` on the reader
## and every later read answers zero without moving - **a truncated stream is
## refused, never silently completed**, which the test asserts directly because
## it is the failure that would otherwise look like a working decode of the
## wrong thing.

const
  MaxVarIntBytes* = 5
  MaxVarLongBytes* = 10
  MaxStringBytes* = 262144
    ## Vanilla caps a string at 32767 *characters*, which is at most three
    ## bytes each plus the prefix. This is that bound, and it is here so that a
    ## lying length cannot make a decoder allocate.

type
  Reader* = object
    data*: seq[int]      ## bytes, 0..255
    at*: int
    problem*: string

  Writer* = object
    data*: seq[int]

  Uuid* = object
    hi*, lo*: int        ## the two big-endian longs, as they arrive

  BlockPos* = object
    x*, y*, z*: int

proc reader*(data: seq[int]): Reader =
  Reader(data: data, at: 0, problem: "")

proc readerFrom*(data: seq[int]; from0, limit: int): Reader =
  ## A reader over a slice, copied so that the slice's end is a real end and a
  ## packet cannot read into the next one.
  var body: seq[int] = @[]
  var i = from0
  while i < limit and i < data.len:
    body.add data[i]
    inc i
  Reader(data: body, at: 0, problem: "")

proc writer*(): Writer =
  Writer(data: @[])

proc ok*(r: Reader): bool = r.problem.len == 0

proc remaining*(r: Reader): int =
  if r.at >= r.data.len: 0 else: r.data.len - r.at

proc fail*(r: var Reader; why: string) =
  if r.problem.len == 0: r.problem = why

# ---------------------------------------------------------------------------
# Bytes and the fixed-width big-endian scalars

proc readByte*(r: var Reader): int =
  ## One unsigned byte. This is the only place that touches `data` directly, so
  ## it is the only place that can run off the end.
  if not ok(r): return 0
  if r.at >= r.data.len:
    fail(r, "read past the end")
    return 0
  result = r.data[r.at] and 0xFF
  inc r.at

proc readSByte*(r: var Reader): int =
  let v = readByte(r)
  if v >= 128: v - 256 else: v

proc readBool*(r: var Reader): bool =
  readByte(r) != 0

proc readUShort*(r: var Reader): int =
  let a = readByte(r)
  let b = readByte(r)
  (a shl 8) or b

proc readShort*(r: var Reader): int =
  let v = readUShort(r)
  if v >= 32768: v - 65536 else: v

proc readUInt*(r: var Reader): int =
  let a = readByte(r)
  let b = readByte(r)
  let c = readByte(r)
  let d = readByte(r)
  (a shl 24) or (b shl 16) or (c shl 8) or d

proc readInt*(r: var Reader): int =
  let v = readUInt(r)
  if v >= 2147483648: v - 4294967296 else: v

proc readLong*(r: var Reader): int =
  ## Eight big-endian bytes as a signed 64-bit value. `shl` wraps, so the top
  ## byte lands on the sign bit by itself and nothing has to special-case it.
  let a = readByte(r)
  let b = readByte(r)
  let c = readByte(r)
  let d = readByte(r)
  let e = readByte(r)
  let f = readByte(r)
  let g = readByte(r)
  let h = readByte(r)
  (a shl 56) or (b shl 48) or (c shl 40) or (d shl 32) or
    (e shl 24) or (f shl 16) or (g shl 8) or h

proc powerOfTwo(n: int): float =
  ## 2^n, by multiplying. There is no `math` here - these modules import
  ## nothing at all so that the mod builder and nimony compile exactly the same
  ## file - and the exponent of a single is between -149 and 127, so this is at
  ## most a hundred and fifty steps and every one of them is exact.
  result = 1.0
  var i = 0
  if n >= 0:
    while i < n:
      result = result * 2.0
      inc i
  else:
    while i < -n:
      result = result * 0.5
      inc i

proc readFloat*(r: var Reader): float =
  ## IEEE-754 single, assembled with arithmetic.
  ##
  ## THIS USED TO BE `float(cast[float32](int32(bits)))`, WHICH IS RIGHT IN NIM
  ## AND WRONG IN THIS INTERPRETER. `aowli` reinterprets the integer at the
  ## width it already has rather than at the width being cast to, so the four
  ## bytes of `20.0f` - 0x41A00000 - came back as the double with that bit
  ## pattern, 5.4e-315. Every float on the wire was silently nonsense in the
  ## running game: health, saturation, the experience bar, a sound's volume and
  ## pitch, an entity's velocity, and the yaw and pitch of a rotation packet.
  ##
  ## And nothing caught it, because `Tests/mcplay_test.exe` is compiled by Nim,
  ## where the cast is correct. `readDouble`'s `cast[float64]` reinterprets an
  ## integer as a value of the same width and does work; this one crossed a
  ## width, and the crossing is the whole of the difference. There is no cast
  ## here now, so there is nothing left to differ.
  let bits = readUInt(r)
  if not ok(r): return 0.0
  let sign = (bits shr 31) and 1
  let exponent = (bits shr 23) and 0xFF
  let fraction = bits and 0x7FFFFF
  var value = 0.0
  if exponent == 0:
    # Subnormal: no implied leading one, and the exponent is the smallest there
    # is rather than the zero it is written as.
    value = float(fraction) * powerOfTwo(-149)
  elif exponent == 255:
    # Infinity and not-a-number. Nothing Mojang sends is either, and a decoder
    # that answered one would put it in a field something later multiplies a
    # position by - so it is answered as zero, which is what every other
    # out-of-range value in this file does rather than failing the read.
    value = 0.0
  else:
    # 1.fraction x 2^(exponent - 127). The multiplier is 2^-23 exactly, so the
    # whole expression is exact in a double and the answer is the single it
    # came from, to the bit.
    value = (1.0 + float(fraction) * 0.00000011920928955078125) *
            powerOfTwo(exponent - 127)
  if sign == 1: -value else: value

proc readDouble*(r: var Reader): float =
  let bits = readLong(r)
  cast[float64](bits)

# ---------------------------------------------------------------------------
# VarInt and VarLong
#
# Seven bits a byte, least significant group first, `0x80` meaning "another
# byte follows". A negative number is its two's complement, so -1 is five bytes
# of ones and *not* a short encoding: anything that assumes a small magnitude
# means a small encoding is wrong about every negative entity id on the wire.

proc readVarInt*(r: var Reader): int =
  if not ok(r): return 0
  var value = 0
  var count = 0
  while true:
    let b = readByte(r)
    if not ok(r):
      fail(r, "VarInt ran off the end")
      return 0
    value = value or ((b and 0x7F) shl (7 * count))
    inc count
    if (b and 0x80) == 0: break
    if count >= MaxVarIntBytes:
      fail(r, "VarInt longer than five bytes")
      return 0
  # Java accumulates into a 32-bit int, so the fifth byte's high bits are
  # shifted out rather than rejected. Reproduce that exactly, then sign-extend.
  value = value and 0xFFFFFFFF
  if (value and 0x80000000) != 0: value = value - 4294967296
  result = value

proc readVarLong*(r: var Reader): int =
  if not ok(r): return 0
  var value = 0
  var count = 0
  while true:
    let b = readByte(r)
    if not ok(r):
      fail(r, "VarLong ran off the end")
      return 0
    value = value or ((b and 0x7F) shl (7 * count))
    inc count
    if (b and 0x80) == 0: break
    if count >= MaxVarLongBytes:
      fail(r, "VarLong longer than ten bytes")
      return 0
  result = value

proc varIntSize*(value: int): int =
  ## How many bytes `value` encodes to. The framing layer needs it, because it
  ## writes a length prefix whose own size depends on what it is prefixing.
  var v = value and 0xFFFFFFFF
  result = 1
  while v >= 128:
    v = v shr 7
    inc result

# ---------------------------------------------------------------------------
# The composite primitives

proc readBytes*(r: var Reader; count: int): seq[int] =
  result = @[]
  if not ok(r): return
  if count < 0:
    fail(r, "negative byte count")
    return
  if count > remaining(r):
    fail(r, "byte array runs past the end")
    return
  var i = 0
  while i < count:
    result.add r.data[r.at + i]
    inc i
  r.at = r.at + count

proc readString*(r: var Reader): string =
  ## A VarInt byte length then that many bytes of UTF-8, kept as bytes. Nothing
  ## above this layer inspects codepoints, and re-encoding is where a text
  ## decoder normally goes wrong, so it is not re-encoded.
  result = ""
  if not ok(r): return
  let length = readVarInt(r)
  if not ok(r): return
  if length < 0 or length > MaxStringBytes:
    fail(r, "string length out of range")
    return
  if length > remaining(r):
    fail(r, "string runs past the end")
    return
  var i = 0
  while i < length:
    result.add char(r.data[r.at + i])
    inc i
  r.at = r.at + length

proc readUuid*(r: var Reader): Uuid =
  let hi = readLong(r)
  let lo = readLong(r)
  Uuid(hi: hi, lo: lo)

const HexDigits = "0123456789abcdef"

proc hex16*(v: int): string =
  result = ""
  var i = 15
  while i >= 0:
    result.add HexDigits[(v shr (i * 4)) and 0xF]
    dec i

proc text*(u: Uuid): string =
  ## The dashed form, 8-4-4-4-12.
  let a = hex16(u.hi)
  let b = hex16(u.lo)
  result = ""
  var i = 0
  while i < 8:
    result.add a[i]
    inc i
  result.add '-'
  while i < 12:
    result.add a[i]
    inc i
  result.add '-'
  while i < 16:
    result.add a[i]
    inc i
  result.add '-'
  i = 0
  while i < 4:
    result.add b[i]
    inc i
  result.add '-'
  while i < 16:
    result.add b[i]
    inc i

proc signExtend*(value, bits: int): int =
  ## `value`'s low `bits` bits read as two's complement.
  let mask = (1 shl bits) - 1
  let v = value and mask
  if (v and (1 shl (bits - 1))) != 0: v - (1 shl bits) else: v

proc unpackPosition*(packed: int): BlockPos =
  ## **The 1.14 packing**, which is still the one at protocol 774: x in the top
  ## 26 bits, then z in the next 26, then y in the low 12. Before 1.14 it was
  ## x, y, z in that order, so a decoder written from an old page reads y and z
  ## swapped, and is wrong by up to two thousand blocks rather than by a
  ## little.
  let x = signExtend(packed shr 38, 26)
  let z = signExtend(packed shr 12, 26)
  let y = signExtend(packed, 12)
  BlockPos(x: x, y: y, z: z)

proc packPosition*(p: BlockPos): int =
  ((p.x and 0x3FFFFFF) shl 38) or ((p.z and 0x3FFFFFF) shl 12) or (p.y and 0xFFF)

proc readPosition*(r: var Reader): BlockPos =
  unpackPosition(readLong(r))

proc readAngle*(r: var Reader): float =
  ## A byte covering a whole turn, so one step is 1/256 of 360 degrees.
  float(readByte(r)) * 360.0 / 256.0

proc packAngle*(degrees: float): int =
  ## Back to a byte. The turn is wrapped positive first and then truncated,
  ## which is what the client's own `(byte)(yaw * 256.0F / 360.0F)` amounts to.
  var t = degrees
  while t < 0.0: t = t + 360.0
  while t >= 360.0: t = t - 360.0
  result = int(t * 256.0 / 360.0) and 0xFF

# ---------------------------------------------------------------------------
# Writing, which exists so that every read can be round-tripped

proc putByte*(w: var Writer; v: int) =
  w.data.add v and 0xFF

proc putBool*(w: var Writer; v: bool) =
  if v: w.data.add 1 else: w.data.add 0

proc putShort*(w: var Writer; v: int) =
  putByte(w, v shr 8)
  putByte(w, v)

proc putInt*(w: var Writer; v: int) =
  putByte(w, v shr 24)
  putByte(w, v shr 16)
  putByte(w, v shr 8)
  putByte(w, v)

proc putLong*(w: var Writer; v: int) =
  putByte(w, v shr 56)
  putByte(w, v shr 48)
  putByte(w, v shr 40)
  putByte(w, v shr 32)
  putByte(w, v shr 24)
  putByte(w, v shr 16)
  putByte(w, v shr 8)
  putByte(w, v)

proc putDouble*(w: var Writer; v: float) =
  putLong(w, cast[int64](v))

proc singleBits*(v: float): int =
  ## The bits of the IEEE-754 single nearest `v`, by arithmetic.
  ##
  ## `cast[int32](float32(v))` was here and is wrong in the interpreter for the
  ## same reason `readFloat`'s cast was - see the note there. This mattered more
  ## than the read did: yaw and pitch go out through `putFloat`, so every look
  ## direction this client ever sent a real server was four bytes of a bit
  ## pattern belonging to a double.
  if v == 0.0: return 0
  var x = v
  var sign = 0
  if x < 0.0:
    sign = 1
    x = -x
  # v = x * 2^exponent, with x brought into [1, 2) unless the exponent has hit
  # the floor - which is what a subnormal is.
  var exponent = 0
  while x >= 2.0 and exponent < 128:
    x = x * 0.5
    inc exponent
  while x < 1.0 and exponent > -127:
    x = x * 2.0
    dec exponent
  if exponent > 127:
    # Larger than a single can hold. The largest finite single, rather than an
    # infinity: nothing on this wire is an infinity and a decoder on the far
    # side is entitled to multiply a position by whatever this says.
    return (sign shl 31) or (254 shl 23) or 0x7FFFFF
  if exponent == -127:
    # Subnormal: no implied leading one. The unit is 2^-149, and x is already
    # v scaled by 2^127, so the step from one to the other is 2^22.
    #
    # The test is on the exponent alone and not on `x < 1.0` as well, which it
    # was: the loop above stops either when x reaches one or when the exponent
    # reaches its floor, and the largest subnormals reach the floor with x
    # almost two. Those - the thirty-two out of twenty thousand this caught -
    # took the normal path and came back with the wrong exponent. A number that
    # is subnormal is exactly a number whose exponent hit the floor.
    var frac = int(x * 4194304.0 + 0.5)
    if frac > 8388607: frac = 8388607
    return (sign shl 31) or frac
  var frac = int((x - 1.0) * 8388608.0 + 0.5)
  var biased = exponent + 127
  if frac > 8388607:
    # Rounded up past the top of the mantissa, which is one more exponent.
    frac = 0
    inc biased
    if biased > 254: return (sign shl 31) or (254 shl 23) or 0x7FFFFF
  (sign shl 31) or (biased shl 23) or frac

proc putFloat*(w: var Writer; v: float) =
  ## The IEEE-754 single. `readFloat` narrows to a single on the way in, so this
  ## narrows on the way out, and the pair is a round trip for every value a
  ## single can hold - which is the only claim either of them can make.
  putInt(w, singleBits(v) and 0xFFFFFFFF)

proc putVarInt*(w: var Writer; value: int) =
  ## Two's complement in 32 bits, so a negative number is always five bytes.
  var v = value and 0xFFFFFFFF
  while true:
    if v < 128:
      putByte(w, v)
      break
    putByte(w, (v and 0x7F) or 0x80)
    v = v shr 7

proc putVarLong*(w: var Writer; value: int) =
  var v = value
  var count = 0
  while true:
    inc count
    let piece = v and 0x7F
    # An arithmetic shift would never terminate on a negative, so the sign bit
    # is cleared by hand on the way down. Ten bytes is the whole of a long.
    v = (v shr 7) and 0x1FFFFFFFFFFFFFF
    if v == 0 or count == MaxVarLongBytes:
      putByte(w, piece)
      break
    putByte(w, piece or 0x80)

proc putBytes*(w: var Writer; b: seq[int]) =
  var i = 0
  while i < b.len:
    w.data.add b[i] and 0xFF
    inc i

proc putString*(w: var Writer; s: string) =
  putVarInt(w, s.len)
  var i = 0
  while i < s.len:
    w.data.add int(s[i]) and 0xFF
    inc i

proc putUuid*(w: var Writer; u: Uuid) =
  putLong(w, u.hi)
  putLong(w, u.lo)

proc putPosition*(w: var Writer; p: BlockPos) =
  putLong(w, packPosition(p))
