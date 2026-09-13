## Deterministic noise, in integers, with no host call and no library.
##
## The whole terrain is a function of the seed and the world coordinate, which
## is what makes a world reproducible without saving it: the same seed builds
## the same hills on any machine, and a chunk a long way from the player can be
## thrown away and generated again rather than kept.
##
## Determinism is the property under test, so nothing here is allowed to use a
## float where an integer would do. The hash is integer arithmetic masked to 32
## bits at every step - the interpreter's `int` is 64 bits wide and an unmasked
## multiply would drift between it and any other width - and the only floats are
## the interpolation at the end.

const
  Mask* = 0xFFFFFFFF
  LacunarityDefault* = 2.0
  GainDefault* = 0.5
    ## How one octave relates to the one before it. Named rather than written
    ## twice, because `fbm2Flat` at the bottom of this file has to agree with
    ## `fbm2` exactly, and a constant that lived only in a signature default is
    ## a constant that can drift out from under the copy.

proc mix32*(value: int): int =
  ## A single-word avalanche, so two coordinates a block apart give two numbers
  ## that share nothing. This is the same shape as the usual xor-shift-multiply
  ## finaliser, with every step masked back into 32 bits.
  var h = value and Mask
  h = (h xor (h shr 16)) and Mask
  h = (h * 0x7feb352d) and Mask
  h = (h xor (h shr 15)) and Mask
  h = (h * 0x846ca68b) and Mask
  h = (h xor (h shr 16)) and Mask
  h

## One number for one place. The coordinates are folded into a word with two
## large odd multipliers so that a lattice does not repeat along an axis.
proc hash2*(seed, x, y: int): int =
  mix32(((x * 0x27d4eb2d) and Mask) + ((y * 0x165667b1) and Mask) +
        ((seed * 0x9e3779b1) and Mask))

proc hash3*(seed, x, y, z: int): int =
  mix32(((x * 0x27d4eb2d) and Mask) + ((y * 0x85ebca6b) and Mask) +
        ((z * 0x165667b1) and Mask) + ((seed * 0x9e3779b1) and Mask))

## The same number as a fraction of one. Exactly 0.0 <= v < 1.0, always, which
## the test asserts over a few thousand samples because every layer above
## depends on it.
proc unit2*(seed, x, y: int): float = float(hash2(seed, x, y)) / 4294967296.0
proc unit3*(seed, x, y, z: int): float = float(hash3(seed, x, y, z)) / 4294967296.0

## Floor as an integer. Nim's `int()` truncates toward zero, which puts every
## cell between -1 and 0 into the same lattice square as the one between 0 and
## 1, and that shows up as a seam along the origin - the classic one.
proc floorInt*(v: float): int =
  let t = int(v)
  if v < 0.0 and float(t) != v: return t - 1
  t

proc fadeCurve*(t: float): float =
  ## Smoothstep. Perlin's quintic is smoother but its second derivative is not
  ## something a block world can see, and this is two multiplies rather than
  ## four.
  t * t * (3.0 - 2.0 * t)

## Value noise on a unit lattice, bilinearly interpolated. 0.0 .. 1.0.
proc valueNoise2*(seed: int; x, y: float): float =
  let ix = floorInt(x)
  let iy = floorInt(y)
  let fx = fadeCurve(x - float(ix))
  let fy = fadeCurve(y - float(iy))
  let a = unit2(seed, ix, iy)
  let b = unit2(seed, ix + 1, iy)
  let c = unit2(seed, ix, iy + 1)
  let d = unit2(seed, ix + 1, iy + 1)
  let top = a + (b - a) * fx
  let bottom = c + (d - c) * fx
  top + (bottom - top) * fy

## The same on a three-dimensional lattice, which is what carves caves: a value
## above a threshold anywhere underground is air.
proc valueNoise3*(seed: int; x, y, z: float): float =
  let ix = floorInt(x)
  let iy = floorInt(y)
  let iz = floorInt(z)
  let fx = fadeCurve(x - float(ix))
  let fy = fadeCurve(y - float(iy))
  let fz = fadeCurve(z - float(iz))
  var corner: array[8, float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
  var i = 0
  while i < 8:
    corner[i] = unit3(seed, ix + (i and 1), iy + ((i shr 1) and 1),
                      iz + ((i shr 2) and 1))
    inc i
  var lane: array[4, float] = [0.0, 0.0, 0.0, 0.0]
  i = 0
  while i < 4:
    lane[i] = corner[i * 2] + (corner[i * 2 + 1] - corner[i * 2]) * fx
    inc i
  let front = lane[0] + (lane[1] - lane[0]) * fy
  let back = lane[2] + (lane[3] - lane[2]) * fy
  front + (back - front) * fz

## Several octaves of it, each half the size and a fraction of the weight. The
## result is renormalised by the total weight, so it is still 0.0 .. 1.0 however
## many octaves were asked for - which is what lets a caller change the detail
## without the sea level moving.
proc fbm2*(seed: int; x, y: float; octaves: int;
           lacunarity = LacunarityDefault; gain = GainDefault): float =
  var sum = 0.0
  var weight = 0.0
  var amplitude = 1.0
  var frequency = 1.0
  var octave = 0
  while octave < octaves:
    sum = sum + valueNoise2(seed + octave * 1013, x * frequency, y * frequency) *
      amplitude
    weight = weight + amplitude
    amplitude = amplitude * gain
    frequency = frequency * lacunarity
    inc octave
  if weight <= 0.0: return 0.0
  sum / weight

proc fbm3*(seed: int; x, y, z: float; octaves: int;
           lacunarity = LacunarityDefault; gain = GainDefault): float =
  var sum = 0.0
  var weight = 0.0
  var amplitude = 1.0
  var frequency = 1.0
  var octave = 0
  while octave < octaves:
    sum = sum + valueNoise3(seed + octave * 1013, x * frequency, y * frequency,
      z * frequency) * amplitude
    weight = weight + amplitude
    amplitude = amplitude * gain
    frequency = frequency * lacunarity
    inc octave
  if weight <= 0.0: return 0.0
  sum / weight

## A ridge rather than a hill: the noise folded about its middle, which turns
## the smooth blobs of value noise into something with edges and makes a range
## of mountains out of a field of lumps.
proc ridged2*(seed: int; x, y: float; octaves: int): float =
  let v = fbm2(seed, x, y, octaves)
  let folded = 1.0 - (if v > 0.5: (v - 0.5) * 2.0 else: (0.5 - v) * 2.0)
  folded * folded

# ---------------------------------------------------------------------------
# The same thing, flattened
#
# Everything above is written to be read, and every layer of it is a call: one
# `fbm2` of four octaves is four `valueNoise2`, each of which is two `floorInt`,
# two `fadeCurve` and four `unit2`, each of which is a `hash2`, which is a
# `mix32`. That is about a hundred and twenty interpreted calls to answer where
# the ground is at one column, and an interpreted call costs 2.1 microseconds
# against 0.28 for a loop iteration - so the calls, not the arithmetic, are what
# a column is made of.
#
# `fbm2Flat` is `fbm2` with all of that written out into one body: the same
# operations in the same order on the same values, with nothing between them.
# It is deliberately, tediously literal - the four corners are four copies of
# `mix32` rather than a loop over an array, because an array index is 0.42
# microseconds and a straight line is free.
#
# The pair is a hazard and the test is what makes it safe:
# `Tests/voxel_test.nim` asserts `fbm2Flat` is *bit-identical* to `fbm2` over
# thousands of columns and octave counts, so the readable one stays the
# specification and this one cannot drift from it without the build going red.
# If you change one, change both.

proc fbm2Flat*(seed: int; x, y: float; octaves: int): float =
  ## `fbm2(seed, x, y, octaves)` with the default lacunarity and gain, inlined.
  var sum = 0.0
  var weight = 0.0
  var amplitude = 1.0
  var frequency = 1.0
  var octave = 0
  while octave < octaves:
    let s = seed + octave * 1013
    let px = x * frequency
    let py = y * frequency

    # floorInt, twice.
    var ix = int(px)
    if px < 0.0 and float(ix) != px: ix = ix - 1
    var iy = int(py)
    if py < 0.0 and float(iy) != py: iy = iy - 1

    # fadeCurve, twice.
    let tx = px - float(ix)
    let ty = py - float(iy)
    let fx = tx * tx * (3.0 - 2.0 * tx)
    let fy = ty * ty * (3.0 - 2.0 * ty)

    # The three parts of `hash2` that do not change across the four corners,
    # and the two that take only two values each.
    let sw = (s * 0x9e3779b1) and Mask
    let xw0 = (ix * 0x27d4eb2d) and Mask
    let xw1 = ((ix + 1) * 0x27d4eb2d) and Mask
    let yw0 = (iy * 0x165667b1) and Mask
    let yw1 = ((iy + 1) * 0x165667b1) and Mask

    # mix32 of each corner, written out four times.
    var ha = (xw0 + yw0 + sw) and Mask
    ha = (ha xor (ha shr 16)) and Mask
    ha = (ha * 0x7feb352d) and Mask
    ha = (ha xor (ha shr 15)) and Mask
    ha = (ha * 0x846ca68b) and Mask
    ha = (ha xor (ha shr 16)) and Mask

    var hb = (xw1 + yw0 + sw) and Mask
    hb = (hb xor (hb shr 16)) and Mask
    hb = (hb * 0x7feb352d) and Mask
    hb = (hb xor (hb shr 15)) and Mask
    hb = (hb * 0x846ca68b) and Mask
    hb = (hb xor (hb shr 16)) and Mask

    var hc = (xw0 + yw1 + sw) and Mask
    hc = (hc xor (hc shr 16)) and Mask
    hc = (hc * 0x7feb352d) and Mask
    hc = (hc xor (hc shr 15)) and Mask
    hc = (hc * 0x846ca68b) and Mask
    hc = (hc xor (hc shr 16)) and Mask

    var hd = (xw1 + yw1 + sw) and Mask
    hd = (hd xor (hd shr 16)) and Mask
    hd = (hd * 0x7feb352d) and Mask
    hd = (hd xor (hd shr 15)) and Mask
    hd = (hd * 0x846ca68b) and Mask
    hd = (hd xor (hd shr 16)) and Mask

    let a = float(ha) / 4294967296.0
    let b = float(hb) / 4294967296.0
    let c = float(hc) / 4294967296.0
    let d = float(hd) / 4294967296.0

    let top = a + (b - a) * fx
    let bottom = c + (d - c) * fx
    let value = top + (bottom - top) * fy

    sum = sum + value * amplitude
    weight = weight + amplitude
    amplitude = amplitude * GainDefault
    frequency = frequency * LacunarityDefault
    inc octave
  if weight <= 0.0: return 0.0
  sum / weight

proc ridged2Flat*(seed: int; x, y: float; octaves: int): float =
  ## `ridged2(seed, x, y, octaves)` over `fbm2Flat`.
  let v = fbm2Flat(seed, x, y, octaves)
  let folded = 1.0 - (if v > 0.5: (v - 0.5) * 2.0 else: (0.5 - v) * 2.0)
  folded * folded
