## Sines and cosines, without `sin` and `cos`.
##
## ## The constraint, and why this is not a way round it
##
## `sqrt` is the only thing out of `std/math` any shipped mod has ever been
## shown to run inside the interpreter. `vxview.nim` says so and works round it
## honestly: the walking bob is a parabola and the walk direction is quantised
## by two multiplications against a constant, because neither needed a real
## angle. **That was the right answer for both of those and it is still the
## answer for both of those.** Nothing in `vxview` changed.
##
## Entities need something `vxview` did not. A nameplate has to be put where
## the head is *on the screen*, which is a perspective divide by a focal
## length, and a focal length is the tangent of half the field of view. A
## billboard that is not the camera's own quad needs the camera's basis. There
## is no quantisation that answers those: they are real angles and the answer
## is a real number.
##
## So this file computes them **from their series**, which is multiplication
## and addition and nothing else:
##
##     sin x = x - x^3/3! + x^5/5! - x^7/7! + ... - x^19/19! + x^21/21!
##
## after the angle is folded into the eighth of a circle where that series is
## at its best. There is no call to `sin` anywhere in it, no table anybody
## generated with one, and no constant that came out of a calculator except pi
## itself. **It is arithmetic, so the interpreter runs it**, which is exactly
## the property the whole no-trigonometry rule is about.
##
## ## How it is proved
##
## `Tests/entity_test.exe` sweeps every tenth of a degree from -1080 to 1080 -
## three turns each way, so the folding is exercised far outside one circle -
## and compares against **the real `sin` and `cos` out of `std/math`**, which
## the test may call because the test is a native program. The worst error over
## that sweep is printed, and asserted below 1e-12. That is the same standard
## `vxview.bobLike` is held to and for the same reason: the day trigonometry
## does cross the seam, this file can be deleted and nothing that depends on it
## changes.
##
## ## What it costs
##
## About twenty multiplications and ten additions per angle, in the interpreter.
## Two angles a frame for the camera basis, two more per nameplate. It is not
## something to put inside a loop over every vertex of every entity, and
## nothing does: the per-limb animation in `vxanim.nim` needs no angles at all,
## because a limb is a transform the host composes.

const
  Pi* = 3.141592653589793
  HalfPi* = 1.5707963267948966
  TwoPi* = 6.283185307179586
  Degree* = 0.017453292519943295
    ## Radians in one degree. Every angle this mod holds is in degrees, because
    ## every angle the host takes is.

## `sin` on the quarter turn, by its series. Accurate to about 1e-16 over
## [-pi/2, pi/2] and used nowhere else, because outside that range the terms
## start fighting each other.
proc seriesSin(x: float): float =
  let xx = x * x
  # Horner from the tail, so the small terms are added to the small ones
  # first. Written as the reciprocals of the factorials rather than as
  # divisions, because a division in the interpreter costs the same as a
  # multiplication and a constant costs nothing.
  var term = -1.0 / 51090942171709440000.0  # -1/21!
  term = term * xx + 1.0 / 121645100408832000.0  #  1/19!
  term = term * xx - 1.0 / 355687428096000.0     # -1/17!
  term = term * xx + 1.0 / 1307674368000.0       #  1/15!
  term = term * xx - 1.0 / 6227020800.0     # -1/13!
  term = term * xx + 1.0 / 39916800.0       #  1/11!
  term = term * xx - 1.0 / 362880.0         # -1/9!
  term = term * xx + 1.0 / 5040.0           #  1/7!
  term = term * xx - 1.0 / 120.0            # -1/5!
  term = term * xx + 1.0 / 6.0              #  1/3!
  x - x * xx * term

## The angle folded into [-pi, pi). A loop and not a remainder, for the reason
## `vxview.wrapAngle` gives: the sign of `mod` on a negative is exactly the
## sort of thing that is right on one toolchain and wrong on the next.
##
## The division is a SHORTCUT and not part of the answer: it steps a large
## angle down by whole turns so that the loops below are short. Taking it out
## leaves every result bit for bit the same and only makes a big angle slow,
## which was confirmed by taking it out - so do not read it as a third rule
## that has to agree with the other two.
proc foldTurns*(radians: float): float =
  result = radians
  if result >= TwoPi or result < -TwoPi:
    let turns = float(int(result / TwoPi))
    result = result - turns * TwoPi
  while result >= Pi: result = result - TwoPi
  while result < -Pi: result = result + TwoPi

## The sine of an angle in **radians**, for any angle at all.
##
## Folded to [-pi, pi) and then to [-pi/2, pi/2] by `sin(pi - x) = sin x`,
## which is the reflection that makes the series good everywhere.
proc sinOf*(radians: float): float =
  var x = foldTurns(radians)
  if x > HalfPi: x = Pi - x
  elif x < -HalfPi: x = -Pi - x
  seriesSin(x)

## The cosine, which is the sine a quarter turn along. Said this way rather
## than with a second series so that there is one series to be wrong.
proc cosOf*(radians: float): float = sinOf(radians + HalfPi)

## The tangent. Zero where the cosine is, which is not the true answer but is
## the only finite one, and is what a focal length wants at the limit rather
## than an infinity that turns every coordinate downstream into a nonsense.
proc tanOf*(radians: float): float =
  let c = cosOf(radians)
  if c > -1e-12 and c < 1e-12: return 0.0
  sinOf(radians) / c

## The same three in degrees, which is what everything in this mod holds.
proc sinDeg*(degrees: float): float = sinOf(degrees * Degree)
proc cosDeg*(degrees: float): float = cosOf(degrees * Degree)
proc tanDeg*(degrees: float): float = tanOf(degrees * Degree)

## A square root by Newton, for the same reason: there is no `sqrt` on this
## side of the boundary either, and `main.nim` already carries one of these.
## Sixteen steps is more than doubles need and costs nothing at the rate this
## is asked.
proc rootOf*(value: float): float =
  if value <= 0.0: return 0.0
  var guess = value
  if guess < 1.0: guess = 1.0
  var step = 0
  while step < 20:
    guess = 0.5 * (guess + value / guess)
    inc step
  guess

## How long a vector is.
proc lengthOf*(x, y, z: float): float = rootOf(x * x + y * y + z * z)

# ---------------------------------------------------------------------------
# Putting a point on the screen
#
# What a nameplate needs and nothing else does.

type Screened* = object
  ## Where a world point landed on the screen, in the host's own interface
  ## points with 0,0 at the top left - the frame `drawText` takes. `ahead` is
  ## how far in front of the camera it was, and `on` is false when it was
  ## behind, which is the case a perspective divide gets spectacularly wrong if
  ## nobody checks it: a point one metre behind you projects to a point in
  ## front of you, mirrored, and the nameplate of the thing at your back
  ## appears over the thing in front of it.
  x*, y*: float
  ahead*: float
  on*: bool

## The focal length of a camera, in interface points: how far back the eye is
## from a screen of that height at that vertical field of view. This is the one
## tangent in the mod and it is asked once a frame.
proc focalLength*(screenHigh, fieldOfView: float): float =
  let half = tanDeg(fieldOfView * 0.5)
  if half < 1e-9: return screenHigh
  screenHigh * 0.5 / half

## A world point on the screen, given the camera's own three unit directions.
##
## `right`, `up` and `ahead` are the basis the caller already has - the same
## three the hand and the chips are placed with - so this needs no matrix and
## no angles: three dot products and a divide.
proc screenOf*(px, py, pz, ex, ey, ez: float;
               rx, ry, rz, ux, uy, uz, ax, ay, az: float;
               screenWide, screenHigh, focal: float): Screened =
  let dx = px - ex
  let dy = py - ey
  let dz = pz - ez
  let ahead = dx * ax + dy * ay + dz * az
  result = Screened(x: 0.0, y: 0.0, ahead: ahead, on: false)
  if ahead <= 0.05: return
  let across = dx * rx + dy * ry + dz * rz
  let above = dx * ux + dy * uy + dz * uz
  result.x = screenWide * 0.5 + across * focal / ahead
  result.y = screenHigh * 0.5 - above * focal / ahead
  result.on = true
