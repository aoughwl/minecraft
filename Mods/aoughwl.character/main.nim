import jester
import catalogs

## What a control scheme is, and one scheme to start from.
##
## The kinds are the point: a binding catalog says which key performs a named
## action, a setting catalog says how a named number feels. Neither knows what a
## character is, so a top-down game, a tank, a boat or a gamepad scheme is
## another catalog of the same two kinds rather than a change to anything here.
##
## The scheme below is only this mod's opinion. A mod that wants different keys
## publishes its own catalogs and hands those names to configure(); a mod that
## wants most of these publishes the handful it disagrees with, and the later
## entry wins.

proc start() =
  discard bindings("character.controls", "Keys for walking around")
    .put("forward", "W")
    .put("back", "S")
    .put("left", "A")
    .put("right", "D")
    .put("jump", "Space")
    .put("run", "LeftShift")

  discard settings("character.movement", "How walking around feels")
    .put("height", 1.8)
    .put("radius", 0.35)
    .put("eyeHeight", 1.6)
    .put("walkSpeed", 3.2)
    .put("runSpeed", 5.35)
    .put("acceleration", 20.0)
    .put("airAcceleration", 6.5)
    .put("gravity", -24.0)
    .put("jumpHeight", 1.8)
    .put("coyoteTime", 0.12)
    .put("jumpBuffer", 0.14)
    .put("groundStick", -2.0)
    .put("lookSpeed", 0.1)
    .put("pitchLimit", 89.0)
  log("character controls published")
