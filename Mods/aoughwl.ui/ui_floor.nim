## The floor a screen is built on: a clip, a colour, an id, and a pointer.
##
## The SDK's `draw` module gives a mod one rectangle and one run of text at a
## time, and the host's own panel stack gives it one column that cannot nest and
## cannot be cropped. Neither is enough to hold a window with a scrolling list
## inside it, or a grid of slots you can pick a thing up out of. This module is
## the missing half, and every widget in `ui` is written out of it:
##
##   beginFrame()
##   paint(box, style().panel)
##   let t = touch("close", corner)
##   if t.clicked: shut()
##   endFrame()
##
## Four things live here and nothing else does.
##
## **The frame.** Drawing is recorded during a frame and replayed after a camera
## renders, and the runtime calls `drawGui()` from `LateUpdate` - never `OnGUI`,
## which Unity does not run headless. So a frame here is exactly one call of
## `beginFrame()` ... `endFrame()`, and every press, release and drop is derived
## from the two pointer facts those two calls see. `beginFrame(at, down)` takes
## those facts rather than reading them, which is what lets a test - or a mod
## driving its UI from a gamepad, or from a cursor a peer is moving - run the
## whole state machine with no host and no screen at all.
##
## **The clip.** Two halves that are not redundant. The arithmetic here crops a
## rectangle before it is filled and crops a picture along with the part of
## itself that shows, and it is what hit testing and `visible()` read - all of
## which happens with no host in sight, which is what lets a test drive a whole
## screen. The host's scissor, which `pushClip` pushes at the same time, is what
## cuts a **letter**: a rectangle a mod can crop for itself, a glyph it cannot.
## Before there was one, a line of text was drawn only when its whole row fitted
## and `fitted()` was the only way to shorten one; now a list shows a half-row
## and a field scrolls sideways instead of spilling over its border.
##
## **The id.** A widget is told apart from its neighbours by a name, and by the
## names it is nested under: `pushId("bag")` in front of `touch("slot3", r)` is
## `bag/slot3`, so the same list drawn twice on one screen is two lists. The
## stack is frame-scoped and starts empty; nothing about an id survives except
## for the one thing that must - which of them the pointer is holding.
##
## **The pointer.** `touch()` is the whole input state machine: hot, grabbed,
## held, clicked. `drag()` and `dropZone()` are the same machine with a payload
## in it. Everything above this module reads those and never the pointer.

import jester
import vec
import color
import input
import draw
export draw

# ------------------------------------------------------------------- looks --

type Look* = object
  ## Every colour and size the builder layer draws with. It is a plain value in
  ## a `var`, so a mod restyles the whole interface by assigning a new one -
  ## there is no theme registry and no engine-side skin.
  panel*, edge*, ink*, faint*, accent*: Color
  hot*, pressed*, slot*, filled*: Color
  welcome*, refuse*, ghost*: Color
  text*, small*, row*, pad*: float64

proc darkLook*(): Look =
  Look(
    panel: rgb(0.07, 0.08, 0.11, 0.94),
    edge: rgb(0.30, 0.34, 0.41, 0.90),
    ink: rgb(0.93, 0.95, 0.98, 1.0),
    faint: rgb(0.62, 0.68, 0.77, 1.0),
    accent: rgb(0.35, 0.62, 0.95, 1.0),
    hot: rgb(0.18, 0.22, 0.29, 0.95),
    pressed: rgb(0.24, 0.30, 0.40, 1.0),
    slot: rgb(0.11, 0.13, 0.17, 0.85),
    filled: rgb(0.16, 0.19, 0.25, 0.95),
    welcome: rgb(0.35, 0.80, 0.48, 0.85),
    refuse: rgb(0.85, 0.32, 0.32, 0.85),
    ghost: rgb(1.0, 1.0, 1.0, 0.75),
    text: 15.0, small: 13.0, row: 28.0, pad: 8.0)

var styling = darkLook()

## What the builder draws with now.
##
## A proc and not a `var` anyone can reach: nimony hands an exported mutable
## global to another module as `auto`, so a field of one read from `ui` is a
## field of nothing at all and every line that touches it fails to compile.
## Reading it through a proc is two more characters at the call site and
## actually has a type. It is `style` and not `look` because `look()` is already
## the mouse-look delta in `vec`.
proc style*(): Look = styling

## Draw everything differently from here on. There is no theme registry and no
## engine-side skin - the whole of restyling is handing over a new `Look`.
proc restyle*(l: Look) = styling = l

# ---------------------------------------------------------------- geometry --

## The part of `a` that is also inside `b`. Width or height comes back at zero
## when they do not meet, which is what `empty` reads.
proc overlap*(a, b: Rect): Rect =
  var x = a.x
  if b.x > x: x = b.x
  var y = a.y
  if b.y > y: y = b.y
  var right = a.x + a.width
  if b.x + b.width < right: right = b.x + b.width
  var bottom = a.y + a.height
  if b.y + b.height < bottom: bottom = b.y + b.height
  if right < x: right = x
  if bottom < y: bottom = y
  rect(x, y, right - x, bottom - y)

proc empty*(r: Rect): bool = r.width <= 0.0 or r.height <= 0.0

## Whether all of `inner` is inside `outer`.
proc holds*(outer, inner: Rect): bool =
  inner.x >= outer.x and inner.y >= outer.y and
    inner.x + inner.width <= outer.x + outer.width and
    inner.y + inner.height <= outer.y + outer.height

# ------------------------------------------------------------- frame state --

type Touch* = object
  ## What the pointer is doing to one rectangle this frame.
  hot*: bool
    ## The pointer is over it, and nothing drawn later has taken the pointer.
  grabbed*: bool
    ## The button went down on it, this frame.
  held*: bool
    ## The button went down on it and has not come up.
  clicked*: bool
    ## It went down on it and came up on it, this frame.

type Carry* = object
  ## What a drag is carrying. A kind and an id, because that is the vocabulary
  ## a catalog already speaks; a number because a stack of things needs one.
  kind*: string
  id*: string
  count*: int64
  source*: string
    ## The id of the drag source it left, so a move knows where to take it from.
  grip*: Vec2
    ## Where inside the source rectangle the pointer took hold, so the thing
    ## under the pointer does not jump when the drag starts.
  size*: Vec2
    ## How big it was, so the ghost is the same size as the hole it left.

proc carry*(kind, id: string; count: int64 = 1): Carry =
  Carry(kind: kind, id: id, count: count, source: "",
    grip: vec2(0.0, 0.0), size: vec2(0.0, 0.0))

type Drag* = object
  ## What a drag source is doing this frame.
  hot*, held*: bool
  clicked*: bool
    ## Pressed and released without ever crossing the threshold - a click, and
    ## never both a click and a drag.
  dragging*: bool
    ## This source is the one being carried right now.

type Drop* = object
  ## What a drop target is seeing this frame.
  over*: bool
    ## Something it accepts is hovering here. Highlight on this.
  dropped*: bool
    ## It was let go here, this frame.
  load*: Carry

type Landing* = object
  ## Where a drag ended, told the frame after it ended - which is the only way
  ## anyone but the winning target can hear about it, and the only way anyone at
  ## all hears about a drag that landed on nothing.
  happened*: bool
  load*: Carry
  target*: string
    ## Empty when it was dropped on nothing.

const NoCarry = Carry(kind: "", id: "", count: 0, source: "",
  grip: Vec2(x: 0.0, y: 0.0), size: Vec2(x: 0.0, y: 0.0))

const DragThreshold* = 4.0
  ## How far the pointer moves before a press stops being a click and starts
  ## being a drag, in screen pixels.

var
  pointerNow = vec2(0.0, 0.0)
  pointerWas = vec2(0.0, 0.0)
  downNow = false
  downWas = false
  pressedNow = false
  releasedNow = false
  surface = rect(0.0, 0.0, 1280.0, 720.0)
  inFrame = false
  frameCount = 0

  wheelNow = 0.0

  clips: seq[Rect] = @[]
  clipDepth = 0
  clipsSent: seq[bool] = @[]
  silent = false
  ids: seq[string] = @[]
  idDepth = 0

  holder = ""            ## the id the press landed on and still owns
  hotLast = ""           ## the topmost claim of the previous frame
  hotNext = ""           ## the topmost claim of this one

  pressPoint = vec2(0.0, 0.0)
  loaded = NoCarry
  carryLive = false      ## the threshold has been crossed
  targetLast = ""
  targetNext = ""
  landingNow = Landing(happened: false, load: NoCarry, target: "")
  landingNext = Landing(happened: false, load: NoCarry, target: "")

  scrollNames: seq[string] = @[]
  scrollOffsets: seq[float64] = @[]

# ------------------------------------------------------------------ a frame --

## Start a frame from pointer facts you supply. This is the whole seam: nothing
## below reads the host, so a mod - or a headless test - drives the entire
## interface by saying where the pointer is and whether the button is down.
proc beginFrame*(at: Vec2; down: bool; area: Rect; turn = 0.0) =
  wheelNow = turn
  pointerWas = pointerNow
  pointerNow = at
  downWas = downNow
  downNow = down
  pressedNow = down and not downWas
  releasedNow = (not down) and downWas
  surface = area
  inFrame = true
  frameCount = frameCount + 1
  clipDepth = 0
  idDepth = 0
  hotNext = ""
  targetNext = ""
  landingNow = landingNext
  landingNext = Landing(happened: false, load: NoCarry, target: "")
  if pressedNow: pressPoint = at

## The same, reading the pointer and the screen from the host. This is what a
## mod calls at the top of `drawGui()`.
proc beginFrame*() =
  beginFrame(pointer(), held(LeftButton), screen(), wheel())

## Close the frame. Presses are retired here, and a drag that ended this frame
## is written down for the next one to read out of `landing()`.
proc endFrame*() =
  if releasedNow:
    if carryLive:
      var winner = targetLast
      if winner.len == 0: winner = targetNext
      landingNext = Landing(happened: true, load: loaded, target: winner)
    loaded = NoCarry
    carryLive = false
    holder = ""
  hotLast = hotNext
  targetLast = targetNext
  inFrame = false

proc pointerAt*(): Vec2 = pointerNow
proc pointerMoved*(): Vec2 = pointerNow - pointerWas
proc pointerDown*(): bool = downNow
proc pointerPressed*(): bool = pressedNow
proc pointerReleased*(): bool = releasedNow
proc screenArea*(): Rect = surface
proc drawing*(): bool = inFrame
proc frames*(): int = frameCount

# ------------------------------------------------------------------- clips --

proc clipRect*(): Rect =
  if clipDepth == 0: surface else: clips[clipDepth - 1]

## Crop everything drawn until the matching `popClip()` to this rectangle, and
## to whatever was already cropping. Hit testing is cropped with it, so a row
## scrolled out of sight cannot be clicked.
##
## This keeps its own stack **and** pushes the host's scissor, and the two are
## not redundant. The arithmetic here is what hit testing, `visible()` and the
## early-outs read - all of which happen with no host in sight, which is what
## lets a headless test drive a whole screen. The host clip is what cuts a
## **letter**, which mod code cannot do at all: a rectangle can be cropped
## before it is asked for, a glyph cannot. So a rect and a picture are cropped
## twice to exactly the same box - the host intersects with what it already has,
## so pushing an already-cropped rectangle is idempotent - and text, which used
## to be dropped by whole lines, is now cut where the clip is.
proc pushClip*(r: Rect) =
  let box = overlap(r, clipRect())
  if clipDepth < clips.len: clips[clipDepth] = box
  else: clips.add box
  let sent = not silent
  if clipDepth < clipsSent.len: clipsSent[clipDepth] = sent
  else: clipsSent.add sent
  clipDepth = clipDepth + 1
  if sent: clipTo(box.x, box.y, box.width, box.height)

proc popClip*() =
  if clipDepth > 0:
    clipDepth = clipDepth - 1
    if clipsSent[clipDepth]: unclip()

proc visible*(r: Rect): bool = not empty(overlap(r, clipRect()))

# -------------------------------------------------------------------- ids --

## Everything named between here and `popId()` is named inside this. Two copies
## of one list on one screen are two lists because they were pushed apart.
proc pushId*(name: string) =
  if idDepth < ids.len: ids[idDepth] = name
  else: ids.add name
  idDepth = idDepth + 1

proc pushId*(index: int) = pushId($index)

proc popId*() =
  if idDepth > 0: idDepth = idDepth - 1

## The full name of something called `name` here. Widgets do this for you; a mod
## needs it only to talk about a widget it is not currently drawing.
proc here*(name: string): string =
  result = ""
  var i = 0
  while i < idDepth:
    result = result & ids[i] & "/"
    i = i + 1
  result = result & name

# ---------------------------------------------------------------- painting --

## Run a frame's layout without drawing any of it. Hit testing, the clip, the
## ids and the whole drag machine carry on exactly as they were - only the
## host calls stop. That is what a sizing pass wants (lay a panel out, ask how
## tall it came to, draw it for real at that height), and it is what lets a
## headless check drive a real screen with no screen.
proc mute*(on: bool) = silent = on
proc muted*(): bool = silent

## A solid rectangle, cropped to the clip.
proc paint*(r: Rect; c: Color) =
  if silent: return
  let box = overlap(r, clipRect())
  if empty(box): return
  fill(box.x, box.y, box.width, box.height, c.r, c.g, c.b, c.a)

## One line of text inside a rectangle, cut at the clip like everything else.
##
## This used to refuse any row that did not fit the clip whole, because the host
## had no scissor and half a glyph was not something it could draw. It has one
## now, so a scrolling list shows a half-row and a field's text stops at its own
## border. The rectangle here is only the row the line is laid out in - a line
## may legitimately run out of it, which is exactly what a field scrolled
## sideways does - so nothing is refused on its width; the host cuts the letters.
proc paint*(text: string; within: Rect; size: float64; align: Align; c: Color) =
  if silent or text.len == 0: return
  let clip = clipRect()
  if within.y + within.height <= clip.y or within.y >= clip.y + clip.height: return
  if within.x >= clip.x + clip.width: return
  writeIn(text, within.x, within.y, within.width, within.height, size,
    name(align), c.r, c.g, c.b, c.a)

## A picture from this mod's folder, cropped to the clip - the part of the
## picture that survives the crop is the part that is drawn, so an icon in a
## scrolling list is cut off rather than squashed. `from0`/`to` name the part of
## the picture to use at all, in 0..1 with 0 at its top, so a sprite sheet is
## this call with a smaller window.
proc paintImage*(file: string; within: Rect; c: Color;
    fromU = 0.0; fromV = 0.0; toU = 1.0; toV = 1.0) =
  if silent: return
  let box = overlap(within, clipRect())
  if empty(box) or within.width <= 0.0 or within.height <= 0.0: return
  let u0 = fromU + (toU - fromU) * ((box.x - within.x) / within.width)
  let u1 = fromU + (toU - fromU) *
    ((box.x + box.width - within.x) / within.width)
  let v0 = fromV + (toV - fromV) * ((box.y - within.y) / within.height)
  let v1 = fromV + (toV - fromV) *
    ((box.y + box.height - within.y) / within.height)
  drawImage(file, box.x, box.y, box.width, box.height, u0, v0, u1, v1,
    c.r, c.g, c.b, c.a)

## Four thin fills, each cropped like any other.
proc border*(r: Rect; thickness: float64; c: Color) =
  paint(rect(r.x, r.y, r.width, thickness), c)
  paint(rect(r.x, r.y + r.height - thickness, r.width, thickness), c)
  paint(rect(r.x, r.y, thickness, r.height), c)
  paint(rect(r.x + r.width - thickness, r.y, thickness, r.height), c)

## As much of `text` as fits in `width`, with a tail when it did not.
##
## The clip cuts a glyph now, so this is no longer the only way to keep a line
## inside its box - but a line that says "Bandage..." reads better than one cut
## through a letter, so it stays what a list uses. A field with the caret in it
## is the exception and scrolls instead: shortening the line there would put the
## caret in the wrong place.
proc fitted*(text: string; width, size: float64): string =
  if silent: return text
  if textWidth(text, size) <= width: return text
  let tail = "..."
  let room = width - textWidth(tail, size)
  if room <= 0.0: return ""
  var kept = ""
  var i = 0
  while i < text.len:
    var wider = kept
    wider.add text[i]
    if textWidth(wider, size) > room: break
    kept = wider
    i = i + 1
  result = kept & tail

# ------------------------------------------------------------ hit and press --

## The pointer is inside this rectangle and inside the clip. Geometry only: it
## says nothing about who owns the press.
proc over*(r: Rect): bool =
  let box = overlap(r, clipRect())
  if empty(box): return false
  pointerNow.x >= box.x and pointerNow.x <= box.x + box.width and
    pointerNow.y >= box.y and pointerNow.y <= box.y + box.height

## The whole of what the pointer does to a rectangle, under one name.
##
## Whichever widget claims the pointer last in a frame is the topmost one, and
## it learns so on the next frame - so a panel drawn over a list takes the
## click, without anything having to know about layers. While a press is held,
## only the widget it landed on is told about it.
proc touch*(name: string; r: Rect): Touch =
  let id = here(name)
  let inside = over(r)
  if inside: hotNext = id
  var mine = inside and (hotLast == id or hotLast.len == 0)
  if holder.len > 0 and holder != id: mine = false
  result = Touch(hot: mine, grabbed: false, held: false, clicked: false)
  if mine and pressedNow:
    holder = id
    pressPoint = pointerNow
    result.grabbed = true
  if holder == id:
    result.held = downNow
    if releasedNow and inside: result.clicked = true

# --------------------------------------------------------- drag and drop --

proc carrying*(): bool = carryLive
proc carried*(): Carry = loaded
## Whether what is being carried is of this kind - what a drop target asks
## before it lights up.
proc carrying*(kind: string): bool = carryLive and loaded.kind == kind
## Where the ghost of the carried thing belongs: under the pointer, held where
## it was picked up.
proc ghostRect*(): Rect =
  rect(pointerNow.x - loaded.grip.x, pointerNow.y - loaded.grip.y,
    loaded.size.x, loaded.size.y)
## Put down whatever is being carried without anybody catching it. The landing
## is still announced next frame, with no target, so a source can undo.
proc cancelDrag*() =
  if not carryLive: return
  landingNext = Landing(happened: true, load: loaded, target: "")
  loaded = NoCarry
  carryLive = false
  holder = ""

## Where the last drag ended. True for exactly one frame, the frame after the
## release, and true whether or not anything caught it.
proc landing*(): Landing = landingNow

## A thing that can be picked up. Hand it the payload it would carry; it is
## copied only when a drag actually starts, so building one per frame costs a
## few words and no host call.
##
## A press that never moves far is a click and never a drag; a press that moves
## is a drag and never a click. That distinction is the reason this is not just
## `touch()` with a flag.
proc drag*(name: string; r: Rect; load: Carry): Drag =
  let id = here(name)
  let t = touch(name, r)
  result = Drag(hot: t.hot, held: t.held, clicked: false, dragging: false)
  if t.grabbed and not carryLive:
    loaded = load
    loaded.source = id
    loaded.grip = vec2(pointerNow.x - r.x, pointerNow.y - r.y)
    loaded.size = vec2(r.width, r.height)
  if holder == id and downNow and not carryLive:
    let moved = pointerNow - pressPoint
    if len(moved) > DragThreshold: carryLive = true
  if carryLive and loaded.source == id: result.dragging = true
  if t.clicked and not carryLive: result.clicked = true

## Somewhere a drag can be let go. `accepts` is the kind it takes, or empty for
## anything. It answers nothing at all while no drag is live, so a screen full
## of targets costs a comparison each until one starts.
proc dropZone*(name: string; r: Rect; accepts: string): Drop =
  result = Drop(over: false, dropped: false, load: NoCarry)
  if not carryLive: return
  if accepts.len > 0 and accepts != loaded.kind: return
  let id = here(name)
  let inside = over(r)
  if inside: targetNext = id
  if targetLast == id or (targetLast.len == 0 and inside): result.over = true
  if result.over and releasedNow:
    result.dropped = true
    result.load = loaded

# ----------------------------------------------------------------- scroll --

## How far a named region has been scrolled. Kept by name, so it survives the
## region being drawn somewhere else next frame, and survives a hot swap with
## every other mod-level `var`.
proc scrollOf*(id: string): float64 =
  var i = 0
  while i < scrollNames.len:
    if scrollNames[i] == id: return scrollOffsets[i]
    i = i + 1
  result = 0.0

proc setScroll*(id: string; value: float64) =
  var i = 0
  while i < scrollNames.len:
    if scrollNames[i] == id:
      scrollOffsets[i] = value
      return
    i = i + 1
  scrollNames.add id
  scrollOffsets.add value

## How far the wheel turned on this frame, in notches, as `beginFrame()` was
## told it. Positive is away from you. Like the pointer, it is a frame fact
## handed in rather than read here, so a test - or a mod scrolling a list from a
## gamepad stick - drives the same code the mouse does.
proc wheelTurn*(): float64 = wheelNow

## How far the wheel turned over this rectangle - zero when it turned but the
## pointer was somewhere else, or over something the clip has hidden. Two lists
## side by side each scroll only under the pointer, and neither has to know the
## other is there.
proc wheelOver*(r: Rect): float64 =
  if wheelNow == 0.0: return 0.0
  if not over(r): return 0.0
  wheelNow

## Nudge one along - what a mod wires a wheel, a key or a page button to. It is
## no longer the only way a region moves: the wheel is a host call now, and
## from dragging its bar.
proc scrollBy*(id: string; amount: float64) =
  setScroll(id, scrollOf(id) + amount)
