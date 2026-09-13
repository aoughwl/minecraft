## Which of the three views you are in, where the camera goes for it, and what
## the body and the hand do about it.
##
## F5 in Minecraft is three states and not a toggle: inside the head, behind the
## shoulder, and in front looking back. Two of those put the camera four metres
## away from the eye, and a camera four metres away is a camera that walks
## through walls unless somebody stops it - so the pull-back is cast, not
## assumed, and it is cast with the same traversal the crosshair uses rather
## than a second one written beside it (`vxray.nim`, and `traceWorld` over it).
##
## Everything in this file is arithmetic. It calls no host, it holds no
## entities, and it never asks what time it is, which is why
## `Tests/view_test.exe` can settle all of it in a fraction of a second - the
## camera-offset maths, the shortening, the state machine, the head-and-body
## split, and the walking bob.
##
## There is no trigonometry here on purpose. `sqrt` is the only function out of
## `std/math` any shipped mod has been shown to run inside the interpreter
## (`aoughwl.rig`, `aoughwl.skinned`), so the direction the head is
## looking arrives as a vector the host already worked out, the two angles the
## camera is given are the two angles the head has (mirrored, for the view that
## looks back), and the walking bob is a parabola that stands in for a sine to
## better than a twentieth - which `Tests/view_test.exe` checks against the real
## `sin`, rather than taking the claim on trust.

import vxray
import vxblocks
import vxworld

type Perspective* = enum
  Inside
    ## First person. The camera is the eye, there is a hand in the corner of
    ## the screen and there is no player to look at.
  Behind
    ## Third person, over the shoulder: the camera is pulled back along the
    ## reverse of the view ray.
  Facing
    ## Third person, in front: the camera is pushed forward along the view ray
    ## and turned round, so the player is looking into it.

const
  PullDistance* = 4.0
    ## How far the camera would like to be from the eye. Minecraft's number.
  PullPadding* = 0.1
    ## Half the width of the box the camera keeps clear of anything solid. The
    ## camera is a point, but what it draws is a near plane with a size, so a
    ## camera exactly against a face still sees through it.
  HeadTurnLimit* = 50.0
    ## How far the head may be turned away from the body before the body has to
    ## come round with it, in degrees. Minecraft's number.
  BodyTurnRate* = 8.0
    ## How fast the shoulders come round to where the feet are going, per
    ## second. `seconds * this`, clamped, is the blend `bodyYawFor` takes.
  BobStride* = 1.4
    ## How far you walk for one full swing of the arm, in metres. One stride is
    ## two paces, which is why the bob is up twice per cycle and forward once.

# ---------------------------------------------------------------------------
# The state machine

## F5, once. Three states in a ring, in the order Minecraft cycles them.
proc nextPerspective*(p: Perspective): Perspective =
  case p
  of Inside: Behind
  of Behind: Facing
  of Facing: Inside

## The word a play script asserts, and the word a saved setting holds.
proc perspectiveName*(p: Perspective): string =
  case p
  of Inside: "first"
  of Behind: "behind"
  of Facing: "front"

## The same read back. Anything else is first person, because a settings file
## somebody edited by hand should put you back in your own head rather than
## refuse to start.
proc perspectiveOf*(name: string): Perspective =
  if name == "behind": return Behind
  if name == "front": return Facing
  Inside

## Is there a player to draw? Exactly the states that are not inside the head.
proc drawsPlayer*(p: Perspective): bool = p != Inside

## Is there a hand in the corner? Exactly the state that is.
proc drawsHand*(p: Perspective): bool = p == Inside

## Which way the camera is pushed off the eye, along the view ray: nowhere,
## backwards, or forwards.
proc pullSign*(p: Perspective): float =
  case p
  of Inside: 0.0
  of Behind: -1.0
  of Facing: 1.0

# ---------------------------------------------------------------------------
# Angles

## An angle brought back into (-180, 180]. Written as a loop rather than a
## remainder because a yaw that has been added to for an hour is a large number
## and the sign of `mod` on a negative is exactly the sort of thing that is
## right on one toolchain and wrong on the next.
proc wrapAngle*(a: float): float =
  result = a
  while result > 180.0: result = result - 360.0
  while result <= -180.0: result = result + 360.0

## The shortest way round from `a` to `b`, signed: positive is the way yaw
## increases.
proc angleBetween*(a, b: float): float = wrapAngle(b - a)

## What the camera is pointed at. The two third-person views differ only here:
## behind you the camera looks the way you look, and in front of you it looks
## back at you, which is the same ray reversed - pitch negated, yaw turned
## half round.
proc cameraPitch*(p: Perspective; pitch: float): float =
  if p == Facing: return -pitch
  pitch

proc cameraYaw*(p: Perspective; yaw: float): float =
  if p == Facing: return wrapAngle(yaw + 180.0)
  wrapAngle(yaw)

# ---------------------------------------------------------------------------
# The pull-back, and what stops it

type Probe* = object
  ## One corner of the little box the camera keeps clear. The pull-back is cast
  ## from each of them and the shortest answer wins, which is what stops the
  ## camera cutting a corner it passes near - a single ray down the middle
  ## walks straight through the edge of a doorway.
  dx*, dy*, dz*: float

const ProbeCount* = 8

proc probeAt*(i: int; padding: float): Probe =
  ## The eight corners of a cube of side `2 * padding` centred on the eye, in
  ## the order the three bits of `i` name: bit 0 is x, bit 1 is y, bit 2 is z.
  var x = -padding
  var y = -padding
  var z = -padding
  if (i and 1) != 0: x = padding
  if (i and 2) != 0: y = padding
  if (i and 4) != 0: z = padding
  Probe(dx: x, dy: y, dz: z)

## How far back the camera may actually go.
##
## `want` is where it would like to be and the answer is never more than that.
## Each of the eight corners is walked along the pull direction; a corner that
## runs into something solid says the camera may only come as far as the face
## it hit, less the padding that keeps the near plane out of the block. The
## shortest of the eight is the answer, and it is never negative: a head that is
## already inside something gives 0, which is first person, which is the only
## honest thing to do.
##
## The direction must be unit length. `Inside` is 0 without casting anything,
## because a camera that is not moving cannot hit anything.
proc pullBack*(w: World; r: Registry; hx, hy, hz, fx, fy, fz: float;
               p: Perspective; want = PullDistance;
               padding = PullPadding): float =
  if p == Inside: return 0.0
  let sign = pullSign(p)
  let dx = fx * sign
  let dy = fy * sign
  let dz = fz * sign
  result = want
  var i = 0
  while i < ProbeCount:
    let probe = probeAt(i, padding)
    let hit = traceWorld(w, r, hx + probe.dx, hy + probe.dy, hz + probe.dz,
      dx, dy, dz, want + padding)
    if hit.found:
      var reach = hit.distance - padding
      if reach < 0.0: reach = 0.0
      if reach < result: result = reach
    inc i

type Placement* = object
  ## Where the camera goes and which way it faces, ready to be handed to a
  ## transform and to nothing else.
  x*, y*, z*: float
  pitch*, yaw*: float

## The whole answer: an eye at `h`, looking along unit `f` with those two
## angles, in that view, allowed back that far.
proc cameraPlacement*(p: Perspective; hx, hy, hz, fx, fy, fz: float;
                      pitch, yaw, distance: float): Placement =
  let sign = pullSign(p)
  Placement(x: hx + fx * sign * distance, y: hy + fy * sign * distance,
    z: hz + fz * sign * distance,
    pitch: cameraPitch(p, pitch), yaw: cameraYaw(p, yaw))

# ---------------------------------------------------------------------------
# The head and the body

## Which way the feet are going, relative to where the head is pointing.
##
## Eight ways and not a continuous angle, because eight is all the input has:
## the keys are two axes with three values each, and every direction a player
## can ask for is one of these. Quantising is also what keeps this free of
## trigonometry - the octant is decided by two multiplications against
## `tan(22.5)` and a pair of signs, where an angle would need an `arctan2` that
## no shipped mod has been shown to run inside the interpreter.
##
## `ahead` is how much of the velocity is along the way the head is pointing and
## `side` how much is across it, both in the head's own frame. Standing still is
## straight ahead, which is the answer that moves nothing.
proc walkYawFor*(ahead, side: float): float =
  const Tan22 = 0.4142135623730951
  var a = ahead
  if a < 0.0: a = -a
  var s = side
  if s < 0.0: s = -s
  if a == 0.0 and s == 0.0: return 0.0
  var base = 45.0
  if s <= a * Tan22: base = 0.0
  elif a <= s * Tan22: base = 90.0
  if side < 0.0: base = -base
  if ahead < 0.0: return wrapAngle(180.0 - base)
  base

## Which way the body should be pointing after this frame.
##
## The body follows where you are going and the head follows where you are
## looking, and the two are tied together: turn your head far enough and your
## shoulders have to come round. That is the whole rule, and the order matters -
## the body eases towards the way it is walking first, and is *then* dragged the
## rest of the way if the head has got too far ahead of it. Doing it the other
## way round lets a body that is walking one way and looking another oscillate,
## because the ease undoes the drag every frame.
##
## `blend` is how much of the way there one frame goes; 0 is a body that never
## turns and 1 is a body that snaps. `moving` is false when you are standing
## still, and a body that is standing still keeps the way it was pointing until
## the head drags it.
proc bodyYawFor*(bodyYaw, headYaw, moveYaw: float; moving: bool;
                 blend: float): float =
  var body = wrapAngle(bodyYaw)
  if moving:
    var step = blend
    if step < 0.0: step = 0.0
    if step > 1.0: step = 1.0
    body = wrapAngle(body + angleBetween(body, moveYaw) * step)
  let turned = angleBetween(body, wrapAngle(headYaw))
  if turned > HeadTurnLimit:
    body = wrapAngle(headYaw - HeadTurnLimit)
  elif turned < -HeadTurnLimit:
    body = wrapAngle(headYaw + HeadTurnLimit)
  body

## How far the head is turned relative to the body, which is what the head's
## own transform is given once the body has been turned. Never outside the
## limit, because `bodyYawFor` has just made sure of it.
proc headTurn*(bodyYaw, headYaw: float): float =
  angleBetween(wrapAngle(bodyYaw), wrapAngle(headYaw))

# ---------------------------------------------------------------------------
# The hand in the corner, and the bob

## A parabola where a sine belongs.
##
## `4u(1-u)` over the half cycle, signed over the other half: zero at 0, one at
## a quarter, zero at a half, minus one at three quarters, zero again at one,
## and never more than 0.06 away from `sin(2*pi*u)` anywhere in between. It is
## here rather than `sin` because no shipped mod has been shown to run `sin`
## inside the interpreter, and because a bob is a feeling rather than a
## measurement - but the test holds it to the real sine all the same, so the
## day trigonometry does cross the seam this can be deleted and nothing that
## depends on it changes.
proc bobLike*(u: float): float =
  var t = u
  while t >= 1.0: t = t - 1.0
  while t < 0.0: t = t + 1.0
  if t < 0.5:
    let h = t * 2.0
    return 4.0 * h * (1.0 - h)
  let h = (t - 0.5) * 2.0
  -(4.0 * h * (1.0 - h))

## Where in the stride you are, from how far you have walked. Always in [0, 1).
proc bobPhase*(walked: float; stride = BobStride): float =
  if stride <= 0.0: return 0.0
  var t = walked / stride
  while t >= 1.0: t = t - 1.0
  while t < 0.0: t = t + 1.0
  t

type Hand* = object
  ## Where the held item sits, said in the camera's own three directions and in
  ## metres: `right` is towards the right of the screen, `up` towards the top,
  ## `ahead` away from the viewer. `roll` is the turn about the view ray, in
  ## degrees, which is what makes the swing read as a swing rather than a slide.
  right*, up*, ahead*: float
  roll*: float

const
  HandRight* = 0.36
  HandUp* = -0.28
  HandAhead* = 0.52
    ## Where the hand rests when you are standing still: low, right, and far
    ## enough forward not to be inside the near plane.
  BobSway* = 0.06
  BobLift* = 0.045
  BobRoll* = 3.2

## The hand this frame. `speed` is how fast you are going as a fraction of your
## top speed, and it is the only thing that scales the bob: a hand at a
## standstill is exactly the resting hand, whatever the phase says, so a player
## who stops mid-stride does not keep waving.
##
## Two swings up for one swing across, because a stride is two paces: the lift
## reads the phase at double rate, the sway at single. That is the same
## relationship a walk cycle has and it is why the bob does not look like a
## metronome.
proc handAt*(p: Perspective; walked, speed: float;
             stride = BobStride): Hand =
  result = Hand(right: HandRight, up: HandUp, ahead: HandAhead, roll: 0.0)
  if not drawsHand(p): return
  var amount = speed
  if amount < 0.0: amount = 0.0
  if amount > 1.0: amount = 1.0
  if amount == 0.0: return
  let phase = bobPhase(walked, stride)
  let sway = bobLike(phase)
  let lift = bobLike(phase * 2.0)
  result.right = result.right + sway * BobSway * amount
  result.up = result.up + lift * BobLift * amount
  result.roll = sway * BobRoll * amount
