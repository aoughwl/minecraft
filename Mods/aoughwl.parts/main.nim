## The mod that says what a part is. It owns the kind, and it owns the two ways a
## part reference can be written - `builtin://<shape>` and `mod://<file>`. Neither
## is known to the host: both are entries this mod puts in the scheme catalog at
## start(), each naming the proc that answers for it, and when this mod unloads
## the catalog loses them the way a catalog loses any item its owner took away.

import jester

## One flat-shaded triangle. Wound so that a viewer standing where the normal
## points sees the corners in clockwise order, which is the way Unity faces front.
proc face(ax, ay, az, bx, by, bz, cx, cy, cz, nx, ny, nz: float64) =
  let a = addVertex(ax, ay, az)
  addNormal(nx, ny, nz)
  let b = addVertex(bx, by, bz)
  addNormal(nx, ny, nz)
  let c = addVertex(cx, cy, cz)
  addNormal(nx, ny, nz)
  addTriangle(a, b, c)

proc quad(ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz,
    nx, ny, nz: float64) =
  face(ax, ay, az, bx, by, bz, cx, cy, cz, nx, ny, nz)
  face(ax, ay, az, cx, cy, cz, dx, dy, dz, nx, ny, nz)

## The seventh shape. The host has six, and no mod can add to them - so this one
## is not asked for, it is described: a cube with one corner cut away, a unit
## across like the built-in cube, built here out of numbers.
proc wedge() =
  let s = 0.7071067811865476
  beginMesh()
  quad(-0.5, -0.5, -0.5, 0.5, -0.5, -0.5, 0.5, -0.5, 0.5, -0.5, -0.5, 0.5,
    0.0, -1.0, 0.0)
  quad(-0.5, -0.5, -0.5, -0.5, -0.5, 0.5, -0.5, 0.5, 0.5, -0.5, 0.5, -0.5,
    -1.0, 0.0, 0.0)
  quad(0.5, -0.5, -0.5, -0.5, 0.5, -0.5, -0.5, 0.5, 0.5, 0.5, -0.5, 0.5,
    s, s, 0.0)
  face(-0.5, -0.5, -0.5, -0.5, 0.5, -0.5, 0.5, -0.5, -0.5, 0.0, 0.0, -1.0)
  face(-0.5, -0.5, 0.5, 0.5, -0.5, 0.5, -0.5, 0.5, 0.5, 0.0, 0.0, 1.0)
  finishMesh()

## A part reference behind `mod://` is a file inside the mod that contributed the
## catalog entry. Whichever mod provides that file's extension reads it.
proc resolveModFile() =
  useModelFile(partLocator())

## A part reference behind `builtin://` is one of the host's own shapes, except
## for the seventh, which this mod describes instead of asking for.
proc resolveBuiltin() =
  let what = partLocator()
  if what == "wedge":
    wedge()
  else:
    useShape(what)

proc start() =
  defineCatalogKind("aoughwl.part", "text",
    "Anything that can be placed in the world and has a visual asset.")
  provideScheme("builtin", "resolveBuiltin")
  provideScheme("mod", "resolveModFile")
