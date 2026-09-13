## The two shapes every other module here speaks in, and the arithmetic that
## has no host call in it.
##
## A `MRect` is a rectangle of numbers. It is deliberately *not* the SDK's
## `Rect`: everything in this folder is compiled twice - once into the mod, and
## once into `Tests/mcui_test.exe`, which has no ModSdk on its module path at
## all - so a pure module here may import nothing but another pure module here.
## That is the same rule `aoughwl.minecraft`'s ten readers follow and it is
## the whole reason those readers can be proved in a second.
##
## A `Quad` is one call to the host's `drawImage`: where it goes on the screen
## and which part of the atlas fills it. Every drawing rule in this mod - the
## nine-slice, the two-slice a Minecraft button really uses, the dirt tiling,
## the logo, a run of glyphs - answers with a `seq[Quad]` and nothing else, so
## the rule and the drawing of it are separable and only the drawing needs a
## host.

type
  MRect* = object
    x*, y*, w*, h*: float

  Quad* = object
    dest*: MRect   ## where on the screen, in screen pixels
    src*: MRect    ## which part of the picture, in that picture's own pixels

proc mrect*(x, y, w, h: float): MRect =
  MRect(x: x, y: y, w: w, h: h)

proc quad*(dest, src: MRect): Quad =
  Quad(dest: dest, src: src)

proc right*(r: MRect): float = r.x + r.w
proc bottom*(r: MRect): float = r.y + r.h

proc holds*(r: MRect; x, y: float): bool =
  x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h

proc absf*(x: float): float =
  if x < 0.0: -x else: x

## Rounding towards minus infinity, because `int()` truncates towards zero and
## a splash bobbing through zero would jump if it did that here.
proc floorf*(x: float): float =
  let whole = float(int(x))
  if x < 0.0 and whole != x: whole - 1.0 else: whole

const Pi* = 3.14159265358979323846

## Sine, written out rather than imported.
##
## There is no `std/math` on this side of the boundary - a mod links against
## the ModSdk and nothing else - and the splash text's bob is a sine of the
## clock, so this is the one number that has to be made here.
##
## Reduced twice and then six terms of the Taylor series in Horner form. The
## first reduction is by whole turns; the second folds the two outer quarters
## back through `sin(t) = sin(Pi - t)`, and it is the one that matters: the
## series' error grows as the thirteenth power of the argument, so over the
## half-turn it would be about five parts in ten thousand and over the quarter
## it is about two parts in a hundred million. The test asserts that against
## the half-angle and Pythagorean identities rather than against a table copied
## out of anywhere, which is a stronger statement than any table.
proc sine*(x: float): float =
  let turn = Pi * 2.0
  var t = x - floorf(x / turn) * turn
  if t > Pi: t = t - turn
  if t > Pi * 0.5: t = Pi - t
  elif t < -Pi * 0.5: t = -Pi - t
  let s = t * t
  t * (1.0 - s / 6.0 * (1.0 - s / 20.0 * (1.0 - s / 42.0 *
    (1.0 - s / 72.0 * (1.0 - s / 110.0)))))

proc cosine*(x: float): float = sine(x + Pi * 0.5)

# ---------------------------------------------------------------------------
# Reading a list of quads back, which is what makes the drawing rules testable
#
# A rule answers with quads. A test wants to ask "what does the picture look
# like at this point on the screen", so these two turn a list of quads back
# into the mapping it stands for. Nothing in the mod calls them; they exist so
# that an assertion can be about the mapping rather than about the list.

## Which quad covers that point on the screen - the last one, because later
## quads are drawn over earlier ones. -1 when none does.
proc quadAt*(quads: seq[Quad]; x, y: float): int =
  result = -1
  var i = 0
  while i < quads.len:
    if quads[i].dest.holds(x, y): result = i
    inc i

## Where in the picture that point on the screen reads from, in picture pixels.
## `outside` when no quad covers it.
proc sampleAt*(quads: seq[Quad]; x, y: float; outside = -1.0): MRect =
  let i = quadAt(quads, x, y)
  if i < 0: return mrect(outside, outside, 0.0, 0.0)
  let q = quads[i]
  mrect(q.src.x + (x - q.dest.x) / q.dest.w * q.src.w,
        q.src.y + (y - q.dest.y) / q.dest.h * q.src.h, 0.0, 0.0)

## How many picture pixels one screen pixel covers at that point. This is the
## number the whole of the nine-slice exists to hold constant: at an integer
## GUI scale of `s`, every part of every widget must read exactly 1/s, and a
## widget that stretched instead would read something else wherever it was not
## its own natural size.
proc densityAt*(quads: seq[Quad]; x, y: float): float =
  let i = quadAt(quads, x, y)
  if i < 0: return 0.0
  quads[i].src.w / quads[i].dest.w

## What a naive stretch - the thing a nine-slice replaces - would have read at
## that point instead. Kept here rather than in a test so that the comparison
## the test makes is against a mapping spelled once, in the same terms.
proc stretchedSample*(dest, src: MRect; x, y: float): MRect =
  mrect(src.x + (x - dest.x) / dest.w * src.w,
        src.y + (y - dest.y) / dest.h * src.h, 0.0, 0.0)

proc stretchedDensity*(dest, src: MRect): float = src.w / dest.w
