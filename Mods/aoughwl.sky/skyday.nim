## Everything about a Minecraft sky that is arithmetic, and nothing else.
##
## No host call, no texture, no Unity, no frame. A day is a number of ticks; a
## sky colour, a sun direction, a moon phase, a star field and a cloud offset
## are all functions of that one number, which is the whole point: they cannot
## drift apart if none of them keeps its own clock. `main.nim` holds the clock
## and asks this module what the sky looks like at that moment.
##
## Everything here is derived from the published behaviour of the game rather
## than copied out of it - a curve, a rotation and a hash. **No Mojang art and
## no Mojang data are in this file**; the four textures the sky wears come from
## the player's own copy through `aoughwl.minecraft`, and are named, never
## shipped.
##
## The one fact worth stating twice: `celestialAngle` is an angle *in turns*,
## and it is discontinuous at noon by exactly 1.0. That is not a bug and it is
## not fixable - `fract()` has to wrap somewhere - but anything that subtracts
## two of them, or interpolates between two of them, is wrong twice a day.
## Take the cosine first; `cos(2*PI*t)` is continuous through the seam because
## `cos(2*PI) == cos(0)`. `Tests/sky_test.nim` asserts both halves of that.

import std/math

const
  TicksPerDay* = 24000
    ## A Minecraft day. Every other tick constant is a point inside it.
  TicksPerSecond* = 20.0
  SecondsPerDay* = 1200.0
    ## Twenty minutes, which is `TicksPerDay / TicksPerSecond` and is written
    ## out rather than computed so that a test can catch the two disagreeing.
  DawnTick* = 0
  NoonTick* = 6000
  DuskTick* = 12000
  MidnightTick* = 18000

  MoonColumns* = 4
  MoonRows* = 2
  MoonPhases* = 8
    ## `moon_phases.png` is one sheet of four by two.

  CloudHeight* = 192.0
    ## Blocks above y=0, which is where the game puts the cloud layer.
  CloudBlocksPerTick* = 0.03
    ## So 0.6 blocks a second, and 720 blocks - sixty cloud cells - in a day.
  CloudCellBlocks* = 12.0
    ## One pixel of the cloud sheet covers this many blocks.
  CloudSheetPixels* = 256.0

  StarSeed* = 10842
  StarAttempts* = 1500
    ## How many candidates the star field draws. Fewer than this survive: a
    ## candidate outside the unit ball, or too near its middle, is thrown away.
  StarRadius* = 100.0

  SunriseBand* = 0.4
    ## How far either side of the horizon the orange reaches, as a cosine.

type
  Rgb* = object
    r*, g*, b*: float

  Rgba* = object
    r*, g*, b*, a*: float

  Tile* = object
    ## A rectangle of a sprite sheet, in uv. `moonTile` is the only thing that
    ## makes one, and the mesher is the only thing that reads one.
    u0*, v0*, u1*, v1*: float

  Dir* = object
    ## A direction, not a position: `sunDirection` and `moonDirection` are unit
    ## length and the caller decides how far away to draw the quad.
    x*, y*, z*: float

  Star* = object
    x*, y*, z*: float
    size*: float

# ---------------------------------------------------------------------------
# The clock

proc clamp01*(v: float): float =
  if v < 0.0: 0.0 elif v > 1.0: 1.0 else: v

proc clampTo*(v, low, high: float): float =
  if v < low: low elif v > high: high else: v

proc fract*(v: float): float =
  ## The part after the point, always in [0,1) - `v - floor(v)` rather than
  ## `v - trunc(v)`, so that a negative time is a time yesterday and not a
  ## mirror image of one. A world that has run backwards over midnight is not
  ## a case this can afford to get wrong.
  result = v - floor(v)

proc wrapTicks*(ticks: float): float =
  ## Any tick count, brought into one day.
  result = fract(ticks / float(TicksPerDay)) * float(TicksPerDay)

proc ticksAt*(seconds: float; startTick = float(DawnTick);
              dayLength = SecondsPerDay): float =
  ## The tick the world is on after this many seconds of play. `dayLength` is
  ## how long a whole day takes in real seconds, so a modpack can make the day
  ## longer without any other number here changing.
  result = startTick + seconds * (float(TicksPerDay) / dayLength)

proc dayNumber*(ticks: float): int =
  ## Which day it is, counting from zero. This is the one place a total tick
  ## count is not wrapped, because the moon does not repeat daily.
  result = int(floor(ticks / float(TicksPerDay)))

proc dayFraction*(ticks: float): float =
  ## How far through today it is, 0 at dawn.
  result = fract(ticks / float(TicksPerDay))

# ---------------------------------------------------------------------------
# The celestial angle, which is the one number everything else is made of

proc celestialAngle*(ticks: float): float =
  ## Where the sun is, in turns, 0 being straight overhead. Not `dayFraction`:
  ## the sun does not move at a constant rate, it lingers near noon and near
  ## midnight and crosses the horizon quickly, which is what the half-cosine
  ## in the middle of this does.
  ##
  ## **Discontinuous at noon, by exactly one turn.** See the module header.
  let d0 = fract(ticks / float(TicksPerDay) - 0.25)
  let d1 = 0.5 - cos(d0 * PI) / 2.0
  result = (d0 * 2.0 + d1) / 3.0

proc skyDim*(angle: float): float =
  ## How much of the biome's colour the sky is showing: 1 in the day, 0 at
  ## night, and the ramp between them is the reason dusk is not a switch.
  result = clamp01(cos(angle * 2.0 * PI) * 2.0 + 0.5)

proc starBrightness*(angle: float): float =
  ## How visible the stars are; never more than a half, even at midnight.
  let f = clamp01(1.0 - (cos(angle * 2.0 * PI) * 2.0 + 0.25))
  result = f * f * 0.5

proc skyDarken*(angle: float): float =
  ## How dark it is outdoors, 0 at noon and 1 at midnight. A block-light
  ## system multiplies its own daylight contribution by `1 - this`.
  result = clamp01(1.0 - (cos(angle * 2.0 * PI) * 2.0 + 0.2))

proc skyLightLevel*(angle: float): int =
  ## The same thing as one of the sixteen light levels the game counts in.
  result = int((1.0 - skyDarken(angle)) * 15.0 + 0.5)

# ---------------------------------------------------------------------------
# Colour

proc hsvToRgb*(h, s, v: float): Rgb =
  ## Hue in turns. Written out rather than pulled from a library because the
  ## biome sky colour is defined in terms of it and a different rounding here
  ## would move every sky colour by a count.
  let sector = int(floor(h * 6.0)) mod 6
  let f = h * 6.0 - floor(h * 6.0)
  let p = v * (1.0 - s)
  let q = v * (1.0 - s * f)
  let t = v * (1.0 - s * (1.0 - f))
  case sector
  of 0: result = Rgb(r: v, g: t, b: p)
  of 1: result = Rgb(r: q, g: v, b: p)
  of 2: result = Rgb(r: p, g: v, b: t)
  of 3: result = Rgb(r: p, g: q, b: v)
  of 4: result = Rgb(r: t, g: p, b: v)
  else: result = Rgb(r: v, g: p, b: q)

proc biomeSky*(temperature: float): Rgb =
  ## The sky a biome of this temperature has at noon. A hot biome is a paler,
  ## slightly greener blue and a cold one a deeper, slightly purpler one, which
  ## is a hue and a saturation moved by a fraction of the temperature - so a
  ## sky colour is *computed*, never a table, and a biome nobody wrote down
  ## still has one.
  let f = clampTo(temperature / 3.0, -1.0, 1.0)
  result = hsvToRgb(0.62222224 - f * 0.05, 0.5 + f * 0.1, 1.0)

proc skyColour*(temperature, ticks: float): Rgb =
  ## What to clear the frame to. The biome's colour, dimmed by the time of day.
  let angle = celestialAngle(ticks)
  let dim = skyDim(angle)
  let base = biomeSky(temperature)
  result = Rgb(r: base.r * dim, g: base.g * dim, b: base.b * dim)

proc sunriseVisible*(angle: float): bool =
  ## Whether there is an orange band at the horizon at all. True twice a day.
  let f = cos(angle * 2.0 * PI)
  result = f >= -SunriseBand and f <= SunriseBand

proc sunriseGlow*(angle: float): Rgba =
  ## The orange at the horizon, with its own opacity - which is why it does not
  ## have to be blended into `skyColour`: it is drawn over it, at the horizon,
  ## on the sun's side. Zero alpha when `sunriseVisible` is false, so a caller
  ## that forgets to ask draws nothing rather than a band at midnight.
  if not sunriseVisible(angle):
    return Rgba(r: 0.0, g: 0.0, b: 0.0, a: 0.0)
  let f = cos(angle * 2.0 * PI)
  let across = f / SunriseBand * 0.5 + 0.5
  var alpha = 1.0 - (1.0 - sin(across * PI)) * 0.99
  alpha = alpha * alpha
  result = Rgba(r: across * 0.3 + 0.7, g: across * across * 0.7 + 0.2,
                b: 0.2, a: alpha)

proc fogColour*(temperature, ticks: float): Rgb =
  ## What the far plane fades to. The sky, pulled a little toward grey, because
  ## fog the exact colour of the sky makes a flat world with no distance in it.
  ## **This is approximated**, not derived: the game's own fog colour is a
  ## blend of sky, sunrise and biome tints that no mod can see.
  let sky = skyColour(temperature, ticks)
  let lift = 0.12 * skyDim(celestialAngle(ticks))
  result = Rgb(r: sky.r + (0.6 - sky.r) * lift,
               g: sky.g + (0.6 - sky.g) * lift,
               b: sky.b + (0.6 - sky.b) * lift)

proc cloudColour*(ticks: float): Rgb =
  ## Clouds are white by day and very nearly black at night, and they take the
  ## sky's own dimming curve so that they cannot go dark on a different
  ## schedule from the sky behind them.
  let dim = skyDim(celestialAngle(ticks))
  let v = 0.1 + 0.9 * dim
  result = Rgb(r: v, g: v, b: v)

# ---------------------------------------------------------------------------
# Where things are

proc celestialDegrees*(angle: float): float =
  ## The rotation of the whole celestial sphere, in degrees.
  result = angle * 360.0

proc sunDirection*(angle: float): Dir =
  ## Unit length, pointing from the player at the sun. Overhead at noon, and
  ## rising in the east - +x, which is Unity's east too, so nothing has to be
  ## mirrored on the way out.
  let t = angle * 2.0 * PI
  result = Dir(x: -sin(t), y: cos(t), z: 0.0)

proc moonDirection*(angle: float): Dir =
  ## The antipode of the sun, which is why a full moon is at its highest at
  ## midnight without anything saying so.
  let s = sunDirection(angle)
  result = Dir(x: -s.x, y: -s.y, z: -s.z)

proc aboveHorizon*(d: Dir): bool = d.y > 0.0

proc moonPhase*(ticks: float): int =
  ## Which of the eight the moon is showing. A whole day at a time, so it does
  ## not change while anybody is looking at it, and it needs the *total* ticks
  ## rather than today's - the one number in this module that is not wrapped.
  var day = dayNumber(ticks) mod MoonPhases
  if day < 0: day = day + MoonPhases
  result = day

proc moonTile*(phase: int): Tile =
  ## Where that phase sits on the four-by-two sheet. The sheet itself is the
  ## player's own file, named through `published:`; this only says which
  ## eighth of it to put on the quad.
  var p = phase mod MoonPhases
  if p < 0: p = p + MoonPhases
  let col = p mod MoonColumns
  let row = p div MoonColumns
  result = Tile(u0: float(col) / float(MoonColumns),
                v0: float(row) / float(MoonRows),
                u1: float(col + 1) / float(MoonColumns),
                v1: float(row + 1) / float(MoonRows))

proc moonBrightness*(phase: int): float =
  ## How much light a moon of this phase gives: full at 0, none at 4, and the
  ## same on the way back. A quarter step per phase.
  var p = phase mod MoonPhases
  if p < 0: p = p + MoonPhases
  let away = if p <= 4: p else: MoonPhases - p
  result = 1.0 - float(away) * 0.25

# ---------------------------------------------------------------------------
# Clouds

proc cloudDrift*(ticks: float): float =
  ## How far the cloud layer has slid, in blocks. Not wrapped: clouds keep
  ## going, they do not start again at dawn.
  result = ticks * CloudBlocksPerTick

proc cloudUv*(drift: float): float =
  ## That drift as a texture offset. One sheet covers
  ## `CloudSheetPixels * CloudCellBlocks` blocks, so a day's 720 blocks is
  ## a quarter of one pass.
  result = drift / (CloudSheetPixels * CloudCellBlocks)

# ---------------------------------------------------------------------------
# Stars, which are a hash rather than a picture

type JavaRandom* = object
  state*: int

const
  LcgMultiplier = 0x5DEECE66D
  LcgAddend = 0xB
  LcgMask = 0xFFFFFFFFFFFF        ## forty-eight bits

proc seeded*(seed: int): JavaRandom =
  result = JavaRandom(state: (seed xor LcgMultiplier) and LcgMask)

proc nextBits*(r: var JavaRandom; bits: int): int =
  ## One step of the generator, in halves.
  ##
  ## The step is a forty-eight-bit state times a thirty-five-bit multiplier,
  ## which is eighty-three bits of product - it does not fit, and the generator
  ## this reproduces relies on it wrapping. Nim will not wrap it, it will raise,
  ## so the multiply is split at the twenty-fourth bit and each half kept under
  ## sixty bits. The two spellings agree exactly, because the mask is a power of
  ## two below the width the wrap would have used.
  let lo = r.state and 0xFFFFFF
  let hi = r.state shr 24
  let low = lo * LcgMultiplier + LcgAddend
  let high = (hi * LcgMultiplier) and 0xFFFFFF
  r.state = ((high shl 24) + low) and LcgMask
  result = r.state shr (48 - bits)

proc nextFloat*(r: var JavaRandom): float =
  ## Twenty-four bits over two to the twenty-four, which is the generator the
  ## star field is specified in terms of. Reproduced rather than approximated,
  ## because a star field that is not the same star field twice is a star field
  ## that shimmers when the player turns round.
  result = float(r.nextBits(24)) / 16777216.0

proc stars*(count = StarAttempts; radius = StarRadius): seq[Star] =
  ## The star field: `count` candidates on a fixed seed, of which the ones
  ## inside the unit ball and not too near its middle survive, pushed out onto
  ## a sphere of this radius. Deterministic, so the sky is the same sky on
  ## every machine and after every reload.
  result = @[]
  var r = seeded(StarSeed)
  var i = 0
  while i < count:
    inc i
    let x = r.nextFloat() * 2.0 - 1.0
    let y = r.nextFloat() * 2.0 - 1.0
    let z = r.nextFloat() * 2.0 - 1.0
    let size = 0.15 + r.nextFloat() * 0.1
    let d = x * x + y * y + z * z
    if d < 1.0 and d > 0.01:
      let k = radius / sqrt(d)
      result.add Star(x: x * k, y: y * k, z: z * k, size: size)
