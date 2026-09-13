## The Minecraft sky, as far as a mod can reach it.
##
## `skyday.nim` beside this file is the whole of the arithmetic and calls no
## host at all; `Tests/sky_test.exe` proves it. This file is the other half:
## the geometry, the pictures and the one clock, and nothing in it decides
## anything. Every frame it reads one number - how many ticks the world is on -
## and asks `skyday` what that means, so the sky colour, the sun's place, the
## moon's phase, the cloud drift and the daylight level cannot drift apart.
##
## ## Six things, and one root they all hang off
##
## | thing | what it is | rebuilt |
## | --- | --- | --- |
## | dome | an inverted sphere, one flat colour, tinted per frame | never |
## | horizon | a band with an alpha gradient, tinted per frame | never |
## | sun | a quad on the celestial root | never |
## | moon | a quad on the celestial root, uv'd to one of eight | once a day |
## | stars | one mesh of small quads on the celestial root | never |
## | clouds | a tiled plane, slid in x | never |
##
## The celestial root is an object at the player's eye, turned by
## `celestialDegrees(angle)`. Turning one object is what keeps the sun, the
## moon and the stars in the same sky: none of them is positioned per frame.
##
## ## What is faithful, and what is not
##
## Faithful: the day is 24000 ticks in twenty minutes; the celestial angle,
## the sky dimming curve, the sunrise band, the star brightness curve and the
## daylight level are the published curves, unrounded; the biome sky colour is
## computed from temperature rather than looked up; the moon is eight phases
## off a four-by-two sheet, one a day; the clouds sit at y=192 and drift at
## 0.03 blocks a tick; the star field is the published seed and rejection.
##
## **Not faithful, and it is the host's fault rather than a shortcut:**
##
## 1. **The sky is lit.** Every mesh a mod can build gets a Standard-derived
##    material, and there is no unlit shader on the surface. So the dome is
##    shaded by the scene's own sun. The normals here all point at the sun to
##    make that shading uniform rather than a light and a dark half, but the
##    dome still dims as the sun sets *on top of* `skyDim` dimming it, so dusk
##    is darker than it should be and the night sky is black rather than very
##    dark blue. `sky_color` fixes this outright.
## 2. **There is no fog.** `RenderSettings.fog*` is static and the reflection
##    hatch is instance-only, so the far edge of the terrain meets the sky at a
##    hard line. `fogColour` is computed here every frame and goes nowhere.
##    This is the single biggest remaining difference.
## 3. **The dome is a shell, not a background.** It has to sit inside the far
##    clip and outside the render distance, and a mod cannot read or set
##    either. `SkyRadius` is a number picked to suit the voxel world's eight
##    chunks; a modpack that draws further will see the sky cut through it.
##
## docs/HOST-SURFACE.md is where the three walls are written down. None of them
## is a thing this file can route around.

import std/math
import jester
import vec
import color
import parts
import catalogs
import textures
import skyday

const
  Scheme = "aoughwl.sky"
  Parts = "sky.parts"
  Pictures = "aoughwl.minecraft"

  SkyRadius = 380.0
    ## Far enough out to be behind the world and near enough in to be inside
    ## the far clip. Neither of those is readable, so this is a number rather
    ## than a derivation, and it is the first thing to move if the sky cuts
    ## through the terrain.
  CelestialRadius = 340.0
  SunHalfSpan = 34.0
  MoonHalfSpan = 22.0
  CloudSpan = 700.0
  CloudTiles = 8.0
  DomeRings = 12
  DomeSegments = 24
  StarCount = 1500

  ## The four pictures, by the public names `aoughwl.minecraft` publishes
  ## them under. Named, never shipped: the bytes are the player's own copy.
  SunPicture = "environment/sun"
  MoonPicture = "environment/moon_phases"
  CloudPicture = "environment/clouds"

var
  ticks = 0.0
  temperature = 0.8
    ## The biome the player is standing in. Nothing tells this mod that yet, so
    ## it is a temperate one until something does; `skyday.biomeSky` takes a
    ## temperature rather than a biome name for exactly that reason.
  root = nothing()
  dome = nothing()
  horizon = nothing()
  sunQuad = nothing()
  moonQuad = nothing()
  starField = nothing()
  clouds = nothing()
  sunLight = nothing()
  drawnPhase = -1
  building = ""

# ---------------------------------------------------------------------------
# The meshes, built once each

proc buildDome() =
  ## An inverted sphere: wound so the inside faces the player, normals all
  ## pointing straight at the sun rather than outward, so that the lit shader
  ## the host gives every mesh shades the whole dome the same amount instead of
  ## making half of it dark. That is the hack; see the header.
  beginMesh()
  var ring = 0
  var index: seq[int] = @[]
  while ring <= DomeRings:
    let lat = (float(ring) / float(DomeRings)) * 0.5 * PI
    let y = cos(lat) * SkyRadius
    let r = sin(lat) * SkyRadius
    var seg = 0
    while seg <= DomeSegments:
      let lon = (float(seg) / float(DomeSegments)) * 2.0 * PI
      index.add addVertex(cos(lon) * r, y, sin(lon) * r,
                          0.0, 1.0, 0.0,
                          float(seg) / float(DomeSegments),
                          float(ring) / float(DomeRings),
                          1.0, 1.0, 1.0, 1.0)
      inc seg
    inc ring
  let stride = DomeSegments + 1
  ring = 0
  while ring < DomeRings:
    var seg = 0
    while seg < DomeSegments:
      let a = index[ring * stride + seg]
      let b = index[ring * stride + seg + 1]
      let c = index[(ring + 1) * stride + seg + 1]
      let d = index[(ring + 1) * stride + seg]
      # Wound the other way round from a solid sphere: the player is inside it.
      addQuad(d, c, b, a)
      inc seg
    inc ring
  finishMesh()

proc buildHorizon() =
  ## The orange band, as one ring of quads facing inward, opaque at the bottom
  ## and clear at the top. The colour and the strength are set per frame with
  ## one `color()` call; the shape of the fade rides the vertex alpha and never
  ## changes.
  beginMesh()
  var seg = 0
  var lower: seq[int] = @[]
  var upper: seq[int] = @[]
  let r = SkyRadius * 0.98
  while seg <= DomeSegments:
    let lon = (float(seg) / float(DomeSegments)) * 2.0 * PI
    let x = cos(lon) * r
    let z = sin(lon) * r
    lower.add addVertex(x, -SkyRadius * 0.08, z, 0.0, 1.0, 0.0,
                        float(seg) / float(DomeSegments), 1.0,
                        1.0, 1.0, 1.0, 1.0)
    upper.add addVertex(x, SkyRadius * 0.30, z, 0.0, 1.0, 0.0,
                        float(seg) / float(DomeSegments), 0.0,
                        1.0, 1.0, 1.0, 0.0)
    inc seg
  seg = 0
  while seg < DomeSegments:
    addQuad(upper[seg + 1], upper[seg], lower[seg], lower[seg + 1])
    inc seg
  finishMesh()

proc buildCelestialQuad(half, at: float; tile: Tile) =
  ## One quad hanging on the celestial root, facing the middle of it. `at` is
  ## which side: +1 puts it where the sun goes, -1 where the moon goes.
  beginMesh()
  let y = at * CelestialRadius
  let n = -at
  let a = addVertex(-half, y, -half, 0.0, n, 0.0, tile.u0, tile.v1)
  let b = addVertex(half, y, -half, 0.0, n, 0.0, tile.u1, tile.v1)
  let c = addVertex(half, y, half, 0.0, n, 0.0, tile.u1, tile.v0)
  let d = addVertex(-half, y, half, 0.0, n, 0.0, tile.u0, tile.v0)
  if at > 0.0: addQuad(a, b, c, d) else: addQuad(d, c, b, a)
  finishMesh()

proc buildStars() =
  ## Every star as a small quad in the plane it happens to face. Built once and
  ## turned with the celestial root, which is why they wheel overhead rather
  ## than sitting still - and why a star field that was not the same field
  ## twice would be visible as a shimmer.
  beginMesh()
  let field = stars(StarCount, CelestialRadius)
  var i = 0
  while i < field.len:
    let s = field[i]
    inc i
    # A frame for the quad: any two directions across the line of sight.
    var ux = -s.z
    var uz = s.x
    let ul = sqrt(ux * ux + uz * uz)
    if ul < 0.00001: continue
    ux = ux / ul
    uz = uz / ul
    let nl = sqrt(s.x * s.x + s.y * s.y + s.z * s.z)
    let nx = -s.x / nl
    let ny = -s.y / nl
    let nz = -s.z / nl
    # The second axis is the cross of the first with the line of sight. The
    # first axis has no y, which is what takes two terms out of the cross.
    let vx = ny * uz
    let vy = nz * ux - nx * uz
    let vz = -(ny * ux)
    let h = s.size
    let a = addVertex(s.x - ux * h - vx * h, s.y - vy * h, s.z - uz * h - vz * h,
                      nx, ny, nz, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0)
    let b = addVertex(s.x + ux * h - vx * h, s.y - vy * h, s.z + uz * h - vz * h,
                      nx, ny, nz, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0)
    let c = addVertex(s.x + ux * h + vx * h, s.y + vy * h, s.z + uz * h + vz * h,
                      nx, ny, nz, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0)
    let d = addVertex(s.x - ux * h + vx * h, s.y + vy * h, s.z - uz * h + vz * h,
                      nx, ny, nz, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0)
    addQuad(a, b, c, d)
  finishMesh()

proc buildClouds() =
  ## One plane at cloud height, its uv running several times across so the
  ## sheet tiles. **Flat, not fancy.** The game draws clouds as solid slabs
  ## with sides when it can and a plane when it cannot, and a slab is four
  ## times the geometry for a difference nobody sees from underneath - and from
  ## underneath is where a player who has not built a tower is. A slab also
  ## needs the sheet's alpha read to know where its edges are, and reading the
  ## sheet means decoding a PNG the mod was given only a name for.
  beginMesh()
  let h = CloudSpan
  let a = addVertex(-h, CloudHeight, -h, 0.0, 1.0, 0.0, 0.0, 0.0)
  let b = addVertex(h, CloudHeight, -h, 0.0, 1.0, 0.0, CloudTiles, 0.0)
  let c = addVertex(h, CloudHeight, h, 0.0, 1.0, 0.0, CloudTiles, CloudTiles)
  let d = addVertex(-h, CloudHeight, h, 0.0, 1.0, 0.0, 0.0, CloudTiles)
  # Seen from below, which is where the player is.
  addQuad(d, c, b, a)
  finishMesh()

proc resolvePart() =
  ## The one door the host opens for geometry. Which of the six is being asked
  ## for is in the locator; `building` carries the moon's phase across, because
  ## a locator is a string and a phase is the only thing here that changes.
  let want = partRequest()
  case want.locator
  of "dome": buildDome()
  of "horizon": buildHorizon()
  of "sun":
    buildCelestialQuad(SunHalfSpan, 1.0,
      Tile(u0: 0.0, v0: 0.0, u1: 1.0, v1: 1.0))
    useTexture(pictureUri(Pictures, SunPicture))
  of "moon":
    buildCelestialQuad(MoonHalfSpan, -1.0, moonTile(drawnPhase))
    useTexture(pictureUri(Pictures, MoonPicture))
  of "stars": buildStars()
  of "clouds":
    buildClouds()
    useTexture(pictureUri(Pictures, CloudPicture))
  else: discard

## Whether the player's own copy has been read yet and this picture is on
## offer. Asked before spawning rather than inside `resolvePart`, because a
## `useTexture` naming a picture nobody published is refused - correctly - and
## a refusal inside a part request takes the whole spawn with it.
##
## This is what makes the sky work in a modpack with no Minecraft in it at all:
## the dome, the horizon and the stars need no picture and are always there, so
## the worst case is a sky that is the right colour at the right hour with
## nothing hanging in it. The three that do need one appear the moment an
## import finishes, which is a frame or two after the world does.
proc pictureReady(name: string): bool =
  hasImage(pictureUri(Pictures, name))

# ---------------------------------------------------------------------------
# Keeping the sky out of the way of the game

proc unsolid(thing: Entity) =
  ## Every mesh the host builds gets a collider, and a sky the player can walk
  ## into is worse than no sky. There is no call for this; the collider is
  ## reached through the reflection hatch and switched off, which works because
  ## `enabled` is an instance property and a bool. It is the same two lines
  ## `aoughwl.voxel` uses on its highlight cube.
  let box = thing.component("UnityEngine.MeshCollider, UnityEngine.PhysicsModule")
  if not box.isNothing(): box.set("enabled", false)

proc place(thing: Entity; x, y, z: float64) =
  if not thing.isNothing(): thing.position(x, y, z)

# ---------------------------------------------------------------------------

proc start() =
  discard catalog(Parts, "aoughwl.part", "The pieces of the sky")
    .put("dome", Scheme & "://dome")
    .put("horizon", Scheme & "://horizon")
    .put("sun", Scheme & "://sun")
    .put("moon", Scheme & "://moon")
    .put("stars", Scheme & "://stars")
    .put("clouds", Scheme & "://clouds")
  provideScheme(Scheme)

  ticks = float(remember("ticks", int64(DawnTick)))
  drawnPhase = moonPhase(ticks)

  root = createObject("Sky")
  dome = spawnPart(Parts, "dome", 0.0, 0.0, 0.0)
  horizon = spawnPart(Parts, "horizon", 0.0, 0.0, 0.0)
  starField = spawnPart(Parts, "stars", 0.0, 0.0, 0.0)
  unsolid(dome)
  unsolid(horizon)
  unsolid(starField)
  attach(starField, root, false)

  # The sun as a light, so that the world underneath is lit by the same number
  # the sky is painted from. Reflection, because a Light is not on the surface -
  # and this is the one use of the hatch here that is not a workaround: it is
  # what every other mod in the project does for a light.
  let sun = createObject("Sky Sun")
  sunLight = sun.addComponent("UnityEngine.Light, UnityEngine.CoreModule")
  sunLight.set("type", "Directional")
  sunLight.set("shadows", "Soft")
  sunLight.set("shadowStrength", 0.7)

  log("sky: a " & $int(SecondsPerDay) & "-second day, " & $StarCount &
      " star candidates, clouds at y=" & $int(CloudHeight))

proc update() =
  ticks = ticks + deltaTime() * (float(TicksPerDay) / SecondsPerDay)
  let angle = celestialAngle(ticks)
  let sky = skyColour(temperature, ticks)
  let glow = sunriseGlow(angle)
  let sunAt = sunDirection(angle)
  let cloud = cloudColour(ticks)
  let stars = starBrightness(angle)
  let level = skyLightLevel(angle)

  # Everything rides the eye, because a sky is a thing you are always in the
  # middle of. Three positions and one rotation, and nothing else moves.
  let ex = eyeX()
  let ey = eyeY()
  let ez = eyeZ()
  place(root, ex, ey, ez)
  place(dome, ex, ey, ez)
  place(horizon, ex, ey, ez)
  # The clouds slide rather than their texture sliding, because a uv offset
  # would mean rebuilding the mesh every frame. One cloud cell is twelve
  # blocks; the plane is wrapped to one cell so the seam never comes round.
  let drift = cloudDrift(ticks)
  let cell = CloudCellBlocks * (CloudSpan * 2.0 / CloudTiles) / CloudCellBlocks
  place(clouds, ex + (drift - float(int(drift / cell)) * cell), ey, ez)

  # One rotation turns the sun, the moon and the stars together. The angle is
  # in turns and is discontinuous at noon by exactly one turn; a rotation does
  # not care, which is the whole reason this is a rotation and not a lerp.
  if not root.isNothing(): root.rotation(0.0, 0.0, celestialDegrees(angle))

  if not dome.isNothing(): dome.color(sky.r, sky.g, sky.b, 1.0)
  if not horizon.isNothing(): horizon.color(glow.r, glow.g, glow.b, glow.a)
  if not clouds.isNothing(): clouds.color(cloud.r, cloud.g, cloud.b, 0.85)
  if not starField.isNothing(): starField.color(1.0, 1.0, 1.0, stars * 2.0)

  if not sunLight.isNothing():
    # The light and the sky are the same number, so a sunset cannot leave the
    # ground bright or the sky dark.
    let up = if sunAt.y > 0.0: sunAt.y else: 0.0
    sunLight.set("intensity", 0.15 + 0.95 * up)
    sunLight.set("color", if glow.a > 0.05: "#ffd2a0" else: "#fff2d8")
    let sunObject = sunLight
    discard sunObject

  # One phase a day, so this is a rebuild that happens once every twenty
  # minutes rather than once a frame.
  let phase = moonPhase(ticks)

  # The three that wear the player's own pictures, made as soon as those are
  # on offer and not before. The moon is remade when its phase changes, which
  # is once every twenty minutes rather than once a frame - its phase is baked
  # into the quad's texture coordinates and a mesh cannot be edited in place.
  if sunQuad.isNothing() and pictureReady(SunPicture):
    sunQuad = spawnPart(Parts, "sun", 0.0, 0.0, 0.0)
    unsolid(sunQuad)
    attach(sunQuad, root, false)
  if clouds.isNothing() and pictureReady(CloudPicture):
    clouds = spawnPart(Parts, "clouds", 0.0, 0.0, 0.0)
    unsolid(clouds)
  if (moonQuad.isNothing() or phase != drawnPhase) and
      pictureReady(MoonPicture):
    drawnPhase = phase
    if not moonQuad.isNothing(): moonQuad.destroy()
    moonQuad = spawnPart(Parts, "moon", 0.0, 0.0, 0.0)
    unsolid(moonQuad)
    attach(moonQuad, root, false)

  # What this mod will answer for, in the one line `expect state` reads. Said
  # every frame, which is what the convention expects: the last value wins.
  log("[assert] ticks=" & $int(ticks) & " angle=" & $angle &
      " skyred=" & $sky.r & " skyblue=" & $sky.b & " daylight=" & $level &
      " phase=" & $phase & " stars=" & $stars & " drift=" & $int(drift) &
      " pictures=" & $((if sunQuad.isNothing(): 0 else: 1) +
                       (if moonQuad.isNothing(): 0 else: 1) +
                       (if clouds.isNothing(): 0 else: 1)))
  save("ticks", int64(ticks))
