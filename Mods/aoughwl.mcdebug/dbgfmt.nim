## The four numbers THIS mod is the one that knows, written out.
##
## Almost nothing on the debug screen belongs to the debug mod. The chunk is
## the voxel world's, the health is the HUD's, the biome belongs to whatever
## generates one - and each of those arrives over a service from the mod that
## owns it, which is the whole design. What is left is the handful of facts
## that come from the host and are therefore nobody's in particular: where the
## eye is, how big the window is, how fast frames are going by, and which host
## this is. This mod publishes those the same way anybody else publishes
## theirs - a catalog row and a service - so that its own lines go through the
## same door as a stranger's and there is no privileged path to test.
##
## There is no `std/math` on this side of the boundary and no need for one
## here: nothing below is worse than a multiply and a divide. The angles a
## `Facing` line wants are NOT computed here, deliberately - the mod that owns
## the player's head already has its yaw and its pitch as numbers, and deriving
## them back out of a forward vector with an arctangent this module would have
## to write by hand would be worse arithmetic AND worse architecture.

## A number with a fixed count of decimals, the way `%.3f` writes one - which
## is what Minecraft's XYZ line is. Rounded half away from zero, so -0.5 is
## -1 at zero places and 0.4995 is 0.500 at three.
proc fixed*(value: float; places: int): string =
  var v = value
  var sign = ""
  if v < 0.0:
    sign = "-"
    v = -v
  var scale = 1
  var p = 0
  while p < places:
    scale = scale * 10
    inc p
  let scaled = int(v * float(scale) + 0.5)
  # Nothing, rounded, is nothing and has no sign. `-0.000` on a coordinate
  # line reads as a number somebody has got wrong.
  if scaled == 0: sign = ""
  let whole = scaled div scale
  if places <= 0: return sign & $whole
  var frac = $(scaled mod scale)
  while frac.len < places: frac = "0" & frac
  sign & $whole & "." & frac

## Rounding towards minus infinity, because the block a player is standing in
## at x = -0.4 is block -1 and `int()` truncates towards zero and would say 0.
## The same rule `mcuicore.floorf` states for the same reason.
proc wholeBelow*(value: float): int =
  let t = int(value)
  if value < 0.0 and float(t) != value: return t - 1
  t

const
  CoordPlaces*: int = 3
    ## Minecraft's XYZ line is three decimals. Not a taste: at three decimals a
    ## millimetre of drift is visible and at two it is not, and this is the
    ## line people read when they are chasing drift.
  CoordSeparator*: string = " / "
    ## Punctuation. The game's.
  SizeSeparator*: string = "x"

proc coords*(x, y, z: float): string =
  fixed(x, CoordPlaces) & CoordSeparator & fixed(y, CoordPlaces) &
    CoordSeparator & fixed(z, CoordPlaces)

proc blocks*(x, y, z: float): string =
  $wholeBelow(x) & CoordSeparator & $wholeBelow(y) & CoordSeparator &
    $wholeBelow(z)

proc size*(w, h: int): string = $w & SizeSeparator & $h

## Which way a forward vector mostly points, as the axis and its sign. This is
## the half of Minecraft's `Facing` line that is not an angle, and it is the
## half that can be had from a vector without an arctangent: whichever of the
## two horizontal components is bigger, and its sign.
##
## The letters are axes and not words - `+Z`, not "south" - which is both
## honest about what a mod can see and free of anybody's language.
proc axisOf*(forwardX, forwardZ: float): string =
  var ax = forwardX
  if ax < 0.0: ax = -ax
  var az = forwardZ
  if az < 0.0: az = -az
  if az >= ax:
    if forwardZ >= 0.0: return "+Z"
    return "-Z"
  if forwardX >= 0.0: return "+X"
  "-X"

## Frames a second, from a count of frames over a span of seconds. Whole,
## because a debug screen showing 59.87 invites people to read a number that is
## noise; and zero-guarded, because the first frame has no span behind it.
proc rate*(frames: int; seconds: float): int =
  if seconds <= 0.0: return 0
  int(float(frames) / seconds + 0.5)
