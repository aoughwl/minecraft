## What makes a box model look alive: the walk, the head, the death, the fuse
## and the fidget.
##
## ## The one idea this file is built on
##
## **A limb is a transform, so animating it needs no trigonometry at all.**
##
## That is worth spelling out because it is not obvious and it decides the
## whole design. The host takes a rotation as three Euler angles and composes
## it itself (`UnityApi.SetRotation`, `Quaternion.Euler`, which is Ry*Rx*Rz). A
## body that only ever yaws, with a limb hung off it that only ever pitches
## about its own sideways axis, is exactly `rotation(pitch, bodyYaw, 0)` on the
## limb - the two compose in that order by construction. So the mod computes
## **angles in degrees** and hands them over, and the sines and cosines happen
## inside Unity where they are free.
##
## The alternative was to rebuild every entity's mesh every frame the way the
## chips are rebuilt, rotating each corner in the mod. That needs a sine per
## limb and, far worse, it needs 144 `addVertex` crossings per entity per
## frame: a hundred and eighty crossings each, twenty entities, three thousand
## six hundred crossings, two and a half milliseconds before the interpreter
## has done anything. A transform per moving limb is **seven** crossings for a
## humanoid and the host does the matrices. `vxmodel.movingParts` is that
## number per model and `Tests/entity_test.exe` holds every shipped model to a
## budget of it.
##
## So there is no `sin` in this file, and there is no need for one. `vxturn.nim`
## exists for the two things that genuinely are angles - a focal length and a
## camera basis - and this file does not import it.
##
## ## Where the wave comes from
##
## `vxview.bobLike` - the parabola that stands in for a sine to better than a
## twentieth, already shipped, already held against the real sine by
## `Tests/view_test.exe`. Every swing here is that one wave read at a phase.
## One wave means one thing to be wrong, and it means the player's hand and a
## cow's front leg are swinging to the same clock.
##
## ## What is Minecraft's and what is this file's
##
## The *shapes* are Minecraft's: legs and arms in antiphase, a death that rolls
## the body ninety degrees over a second, a creeper that swells and flashes
## faster as its fuse runs out, a head that turns no further than the neck
## allows before the shoulders come with it. The *numbers* are in `vxbeasts`
## where a modpack can change them, and the *method* is this mod's, because
## Minecraft's method is trigonometry and this mod has none.

import vxview
import vxmodel

const
  WalkStride* = BobStride
    ## How far a thing walks for one full swing of a limb, in metres. The
    ## player's, shared deliberately: a player and a zombie walking side by
    ## side that swung to different clocks would read as a bug even though
    ## neither is wrong.
  DeathTime* = 1.0
    ## How long a body takes to fall over, in seconds. Minecraft's twenty
    ## ticks.
  DeathTurn* = 90.0
    ## And how far. A body ends up on its side, not on its face.
  HurtTime* = 0.5
    ## How long the flinch lasts. Minecraft's ten ticks.
  HurtLean* = 14.0
    ## How far the body tips when it is hit, in degrees.
  HurtGlow* = 0.6
    ## How much red is mixed into whatever it is wearing, at the worst of it.
  FuseTime* = 1.5
    ## How long a creeper is primed for, in seconds. Minecraft's thirty ticks.
  SwellMost* = 0.30
    ## How much bigger it gets in that time.
  FlashRate* = 9.0
    ## How the flashing speeds up. The toggle is on the SQUARE of the fuse, so
    ## the gaps shorten as it goes - which is the thing about a creeper that
    ## actually raises the pulse, and it is checked by asserting that every gap
    ## is shorter than the one before rather than by counting them.
  IdleLean* = 1.6
    ## How far a standing thing sways, in degrees. Small on purpose: this is
    ## the difference between a mob and a statue and it should never be the
    ## thing you notice.
  IdlePeriod* = 3.7
    ## Seconds in one sway. Not a round number, so that two mobs standing
    ## beside each other whose clocks differ by anything at all do not fall
    ## into step and read as one object.
  FlapPeriod* = 0.22
    ## A chicken's wing, in seconds per beat.
  CrawlSpread* = 26.0
    ## How far apart a spider's legs sit round its body, in degrees between
    ## one and the next.
  CrawlLift* = 22.0
    ## And how far one lifts as it steps.
  HeadPitchLimit* = 70.0
    ## How far anything may look up or down. A neck, not a camera.

# ---------------------------------------------------------------------------
# The clock
#
# Everything below is a function of two numbers: how far the thing has walked,
# ever, and how fast it is going as a fraction of its own walk. Neither is a
# time, on purpose - a mob walking into a wall stops swinging, and a mob being
# pushed along by a boat swings, which is what you want and is not what a
# clock gives you.

## Where in the stride a thing is, from how far it has walked. Always in [0,1).
proc strideAt*(walked: float; stride = WalkStride): float =
  bobPhase(walked, stride)

## How fast, as a fraction of a walk, clamped. A thing going backwards swings
## the same as a thing going forwards; the direction is in the body's yaw.
proc paceOf*(speed, top: float): float =
  if top <= 0.0: return 0.0
  var pace = speed / top
  if pace < 0.0: pace = -pace
  if pace > 1.0: pace = 1.0
  pace

# ---------------------------------------------------------------------------
# The walk

## Which way round a role swings, as a multiplier on the one wave.
##
## Right leg and left arm together, left leg and right arm together - which is
## how a person walks and why it looks wrong the moment it is not. Everything
## else is still.
proc swingSign*(role: BoxRole): float =
  case role
  of RoleLegRight: 1.0
  of RoleArmLeft: 1.0
  of RoleLegLeft: -1.0
  of RoleArmRight: -1.0
  of RoleTail: 1.0
  else: 0.0

## What a box is pitched to this frame, in degrees about its own sideways axis.
##
## `hold` is where the limb sits whatever happens - a zombie's arms out in
## front - and the swing is added to it. A thing standing still is exactly its
## `hold`, so a mob that stops mid-stride does not keep waving, which is the
## rule the player's hand already follows.
proc limbPitch*(b: Box; phase, pace: float): float =
  let sign = swingSign(b.role)
  if sign == 0.0: return b.hold
  b.hold + b.turn * pace * sign * bobLike(phase)

## A tail, which sways across rather than fore and aft. Same wave, read as a
## yaw.
proc tailYaw*(b: Box; phase, pace: float): float =
  if b.role != RoleTail: return 0.0
  b.turn * pace * bobLike(phase)

# ---------------------------------------------------------------------------
# The head

## How far a head is turned away from its body, and how far up or down, in the
## two limits a neck has.
##
## The yaw half is `vxview.headTurn` and not a second spelling of it: the
## player's head and a cow's head are the same joint, and the player's was
## already written. What is added here is the pitch limit, which the player did
## not need because the player's pitch is the camera's.
proc headYawOf*(bodyYaw, lookYaw: float): float =
  var turned = headTurn(bodyYaw, lookYaw)
  if turned > HeadTurnLimit: turned = HeadTurnLimit
  if turned < -HeadTurnLimit: turned = -HeadTurnLimit
  turned

proc headPitchOf*(pitch: float): float =
  if pitch > HeadPitchLimit: return HeadPitchLimit
  if pitch < -HeadPitchLimit: return -HeadPitchLimit
  pitch

# ---------------------------------------------------------------------------
# The fidget
#
# A mob that is not walking and is not doing anything is still not a statue.
# This is the smallest thing that says so.

## How far a standing thing is leaning this instant. `offset` is the thing's
## own place in the cycle, which is anything at all as long as it differs
## between two mobs - the entity id does perfectly well.
##
## Scaled down by how fast it is going, so a walking mob is animated by the
## walk and a standing one by this, and neither is animated by both.
proc idleLean*(seconds, offset, pace: float): float =
  var rest = 1.0 - pace
  if rest < 0.0: rest = 0.0
  IdleLean * rest * bobLike(bobPhase(seconds, IdlePeriod) + offset)

## A wing. Flaps flat out while the thing is in the air and folds when it is
## not, which is a chicken.
proc wingFlap*(b: Box; seconds: float; falling: bool): float =
  if b.role != RoleWingRight and b.role != RoleWingLeft: return 0.0
  var amount = 0.18
  if falling: amount = 1.0
  var sign = 1.0
  if b.role == RoleWingLeft: sign = -1.0
  b.hold + sign * b.turn * amount * bobLike(bobPhase(seconds, FlapPeriod))

# ---------------------------------------------------------------------------
# A spider's eight legs
#
# `turn` on a `crawl` box is its place in the ring, 0 to 7: four down the right
# side then four down the left. Which is which is decided here and not in the
# data, because the RING is the shape and the data only says where in it.

## How far round the body a leg sits, in degrees of yaw, before it steps.
##
## The four on a side are spread evenly about straight out, and the left side
## is the mirror of the right. A leg's place in the ring is the only thing that
## distinguishes it, which is why eight nearly identical rows in `vxbeasts` are
## not eight nearly identical special cases here.
proc crawlBase*(ring: int): float =
  let side = ring div 4
  let along = float(ring mod 4) - 1.5
  var yaw = along * CrawlSpread
  if side == 1: yaw = -yaw
  yaw

## And which way it is turned right now: the base, plus a step.
##
## The near legs and the far legs step alternately - a spider does not pick up
## one side at a time - so the phase a leg reads is shifted half a stride for
## every other one of them.
proc crawlYaw*(ring: int; phase, pace: float): float =
  let shift = float((ring + ring div 4) mod 2) * 0.5
  crawlBase(ring) + CrawlSpread * 0.5 * pace * bobLike(phase + shift)

## How far it is lifted off the ground as it steps: the same wave a quarter
## along, so a leg is highest halfway through its swing and down at both ends.
proc crawlLift*(ring: int; phase, pace: float): float =
  let shift = float((ring + ring div 4) mod 2) * 0.5
  var sign = 1.0
  if ring div 4 == 1: sign = -1.0
  sign * CrawlLift * pace * bobLike(phase + shift + 0.25)

# ---------------------------------------------------------------------------
# Being hit, and dying

## How far a body has fallen over, in degrees, `since` seconds after it died.
##
## Eased out rather than linear: a body drops fast and settles, which is what a
## square root of the fraction gives and what Minecraft does. The root is
## Newton's, because there is no `sqrt` on this side of the boundary - and
## because the ease is a feeling, `Tests/entity_test.exe` holds it to the
## properties that matter instead: it starts at nothing, it ends flat on the
## ground, it never goes past, and it never comes back up.
proc deathRoll*(since: float): float =
  if since <= 0.0: return 0.0
  var t = since / DeathTime
  if t > 1.0: t = 1.0
  # sqrt(t) by Newton, three steps from a good first guess. Three is enough for
  # a number that ends up multiplied by ninety and rounded onto a transform.
  if t <= 0.0: return 0.0
  var guess = 0.5 * (t + 1.0)
  var step = 0
  while step < 6:
    guess = 0.5 * (guess + t / guess)
    inc step
  DeathTurn * guess

## Whether a body is still falling over. A body that has finished is left where
## it landed until whoever owns the entity takes it away.
proc dying*(since: float): bool = since >= 0.0 and since < DeathTime

## How far a body is tipped by having been hit, `since` seconds after. One
## flinch, decaying, and nothing at all once the flinch is over.
proc hurtLean*(since: float): float =
  if since < 0.0 or since >= HurtTime: return 0.0
  let t = since / HurtTime
  HurtLean * (1.0 - t) * bobLike(t * 0.5)

## And how red it goes: the same flinch as a fraction of a full red.
proc hurtGlow*(since: float): float =
  if since < 0.0 or since >= HurtTime: return 0.0
  let t = since / HurtTime
  HurtGlow * (1.0 - t)

# ---------------------------------------------------------------------------
# A creeper's last second and a half

## How much bigger a creeper is, as a multiplier on its whole model.
##
## Square in the fuse, so nothing much happens for the first second and then it
## goes. A creeper that is not primed is exactly 1.0, which is the thing to
## hold to: an entity whose scale is set every frame to something that should
## be one and is 1.0001 is a thing that shimmers.
proc creeperSwell*(fuse: float): float =
  if fuse <= 0.0: return 1.0
  var t = fuse / FuseTime
  if t > 1.0: t = 1.0
  1.0 + SwellMost * t * t

## Whether it is white this instant.
##
## The toggle runs on the SQUARE of the fuse, which is what makes the gaps
## shorten as it counts down. No wave and no trigonometry: it is whether a
## whole number is even, and the whole number grows faster than the clock.
proc creeperFlash*(fuse: float): bool =
  if fuse <= 0.0: return false
  let ticks = int(fuse * fuse * FlashRate)
  (ticks mod 2) == 1

## How much white is mixed in. Flashing is on or off, and how strong it is when
## it is on grows with the fuse, so the last flash is the brightest.
proc creeperGlow*(fuse: float): float =
  if not creeperFlash(fuse): return 0.0
  var t = fuse / FuseTime
  if t > 1.0: t = 1.0
  0.35 + 0.65 * t

# ---------------------------------------------------------------------------
# What the whole of one entity comes out as
#
# One object rather than eleven out-parameters, because the caller hands every
# field of it straight to a transform and an object is what a test can compare.

type Pose* = object
  ## Where one box of one entity is pointed this frame, in the host's own
  ## degrees. `yaw` is about the world's up, `pitch` about the box's own
  ## sideways axis, `roll` about the way it is pointing - the three
  ## `rotation()` takes, in the order it takes them.
  pitch*, yaw*, roll*: float

## The pose of one box, whatever kind of box it is. The whole of the animation
## for one limb, in one call, so that the caller is a loop over boxes and holds
## no rules of its own.
##
## `bodyYaw` is where the shoulders point and is already decided (`vxview`);
## everything here is relative to it, which is what a transform parented to the
## body wants.
proc poseOf*(b: Box; bodyYaw, lookYaw, lookPitch: float;
             phase, pace, seconds, offset: float;
             falling = false): Pose =
  result = Pose(pitch: 0.0, yaw: bodyYaw, roll: 0.0)
  case b.role
  of RoleHead:
    result.yaw = bodyYaw + headYawOf(bodyYaw, lookYaw)
    result.pitch = headPitchOf(lookPitch)
  of RoleArmRight, RoleArmLeft, RoleLegRight, RoleLegLeft:
    result.pitch = limbPitch(b, phase, pace) + idleLean(seconds, offset, pace)
  of RoleWingRight, RoleWingLeft:
    result.roll = wingFlap(b, seconds, falling)
  of RoleCrawl:
    let ring = int(b.turn)
    result.yaw = bodyYaw + crawlYaw(ring, phase, pace)
    result.roll = crawlLift(ring, phase, pace)
  of RoleTail:
    result.yaw = bodyYaw + tailYaw(b, phase, pace)
  of RoleStill:
    result.pitch = b.hold
  result

## The body's own pose: where the whole thing is pointed, before any limb.
## The death roll and the flinch both live here, because both tip the whole
## model and not a part of it.
proc bodyPose*(bodyYaw, deadFor, hurtFor: float): Pose =
  Pose(pitch: hurtLean(hurtFor), yaw: bodyYaw, roll: deathRoll(deadFor))
