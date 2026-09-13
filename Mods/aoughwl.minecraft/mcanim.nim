## Animated textures: the `.mcmeta` beside a picture, read properly.
##
## Pure: nothing here calls the host.
##
## Ninety-nine vanilla block textures are a vertical strip of square frames -
## fire, water, lava, prismarine, the command block, a beacon - and until now the
## importer took the first frame and said so. That was honest and it was also
## wrong about a fifth of them: `sea_lantern` looks nothing like its first frame,
## and a `frames` list can reorder or repeat frames so that "frame 0" is not even
## the one Minecraft shows first.
##
##     {"animation": {"frametime": 2, "interpolate": true,
##                    "frames": [0, 1, 2, {"index": 3, "time": 20}]}}
##
## Every field is optional. With no `frames` the strip plays in order; with no
## `frametime` each step lasts one tick; a step may be a bare index or an object
## that overrides the time for that one step. `width` and `height` exist for the
## rare non-square frame and are read so a caller is not surprised by one.
##
## What this file gives back is a **schedule**: which frame of the strip is on
## screen at tick *t*, and how long the whole loop is. Nothing here animates -
## a mod does that, by asking `frameAt` once a frame and swapping tiles - and
## nothing here decodes a picture, because the strip is `mcpng`'s business and
## the shape of it is `mcatlas`'s.
##
## A tick is Minecraft's, one twentieth of a second, and it is named in ticks
## rather than in seconds so the numbers in the file are the numbers here.

import mcjson

const
  MaxSteps* = 1024
    ## `clock` has 64 frames and `compass` 32. A file asking for more steps than
    ## this is refused rather than turned into a list that long.
  TicksPerSecond* = 20

type
  Animation* = object
    frame*: seq[int]     ## per step: which frame of the strip
    time*: seq[int]      ## per step: how many ticks it holds
    frametime*: int      ## the default hold, for a step that did not say
    interpolate*: bool   ## blend towards the next step rather than cutting
    frames*: int         ## how many frames the strip actually has
    width*, height*: int ## a frame's own size, 0 when the file did not say
    problem*: string

proc noAnimation*(): Animation =
  Animation(frame: @[], time: @[], frametime: 1, interpolate: false,
            frames: 1, width: 0, height: 0, problem: "")

## The schedule a strip has when no `.mcmeta` said otherwise: every frame in
## order, one tick each. This is what a caller uses for a picture that is a
## strip by its shape and has no metadata file beside it, which does happen.
proc plainAnimation*(frames: int): Animation =
  result = noAnimation()
  if frames < 1:
    result.frames = 1
    result.frame = @[0]
    result.time = @[1]
    return result
  result.frames = frames
  var i = 0
  while i < frames:
    result.frame.add i
    result.time.add 1
    inc i

## Read one `.mcmeta`. `framesInStrip` is what the picture's own shape says -
## `mcatlas.frameCount` - and it is what a listed index is checked against: a
## file naming frame 9 of a four-frame strip is a broken file, and the frame is
## dropped with a reason rather than read off the end of the picture.
##
## **Zero means the strip's length is not known.** A `.mcmeta` does not say how
## many frames its picture has - only the picture does - and there are callers
## that have the one and not the other: reading every `.mcmeta` at import time
## is text work, and opening the pictures is not. With zero, nothing is checked
## against a length nobody has, and a file with no `frames` list comes back with
## no schedule rather than with a fabricated one.
proc readAnimation*(doc: Json; framesInStrip: int): Animation =
  if framesInStrip >= 1: result = plainAnimation(framesInStrip)
  else:
    result = noAnimation()
    result.frames = 0
    result.frame = @[]
    result.time = @[]
  if doc.root < 0:
    result.problem = "this .mcmeta would not parse"
    return result
  let anim = member(doc, doc.root, "animation")
  if anim < 0:
    result.problem = "this .mcmeta has no 'animation'"
    return result
  result.frametime = int(number(doc, member(doc, anim, "frametime"), 1.0))
  if result.frametime < 1: result.frametime = 1
  result.interpolate = truth(doc, member(doc, anim, "interpolate"), false)
  result.width = int(number(doc, member(doc, anim, "width"), 0.0))
  result.height = int(number(doc, member(doc, anim, "height"), 0.0))
  let list = member(doc, anim, "frames")
  if list < 0 or kindAt(doc, list) != jArray or len(doc, list) == 0:
    # No list: every frame in order, at the frametime this file gave.
    var i = 0
    while i < result.time.len:
      result.time[i] = result.frametime
      inc i
    return result
  if len(doc, list) > MaxSteps:
    result.problem = "more than " & $MaxSteps & " animation steps"
    return result
  result.frame = @[]
  result.time = @[]
  var i = 0
  while i < len(doc, list):
    let entry = item(doc, list, i)
    inc i
    var index = 0
    var hold = result.frametime
    if kindAt(doc, entry) == jNumber:
      index = int(number(doc, entry, 0.0))
    elif kindAt(doc, entry) == jObject:
      index = int(number(doc, member(doc, entry, "index"), 0.0))
      hold = int(number(doc, member(doc, entry, "time"), float(result.frametime)))
    else:
      if result.problem.len == 0:
        result.problem = "a frame must be a number or an object"
      continue
    if index < 0 or (framesInStrip >= 1 and index >= framesInStrip):
      if result.problem.len == 0:
        result.problem = "frame " & $index & " is not among the " &
          $framesInStrip & " this picture has"
      continue
    if hold < 1: hold = 1
    result.frame.add index
    result.time.add hold
  if result.frame.len == 0 and framesInStrip >= 1:
    # Everything the file listed was out of range. Fall back to the strip's own
    # order rather than to nothing, so the texture still animates.
    let saved = result.problem
    result = plainAnimation(framesInStrip)
    result.problem = saved

## How long the whole loop lasts, in ticks.
proc loopTicks*(a: Animation): int =
  result = 0
  var i = 0
  while i < a.time.len:
    result = result + a.time[i]
    inc i
  if result < 1: result = 1

proc stepCount*(a: Animation): int = a.frame.len

## Which step of the schedule is showing at a tick. Wraps, and answers for a
## negative tick too, because a caller counting from an arbitrary epoch should
## not have to know where zero is.
proc stepAt*(a: Animation; tick: int): int =
  if a.frame.len == 0: return 0
  var at = tick mod loopTicks(a)
  if at < 0: at = at + loopTicks(a)
  var i = 0
  while i < a.time.len:
    if at < a.time[i]: return i
    at = at - a.time[i]
    inc i
  a.frame.len - 1

## Which frame of the strip is showing at a tick - the answer a mod actually
## wants, once a frame.
proc frameAt*(a: Animation; tick: int): int =
  if a.frame.len == 0: return 0
  a.frame[stepAt(a, tick)]

## The frame it is blending *towards*, and how far. Zero when the file did not
## ask for interpolation, so a caller can always ask and let the file decide.
proc blendAt*(a: Animation; tick: int; nextFrame: var int): float =
  nextFrame = frameAt(a, tick)
  if not a.interpolate or a.frame.len < 2: return 0.0
  let step = stepAt(a, tick)
  nextFrame = a.frame[(step + 1) mod a.frame.len]
  var at = tick mod loopTicks(a)
  if at < 0: at = at + loopTicks(a)
  var i = 0
  while i < step:
    at = at - a.time[i]
    inc i
  if a.time[step] <= 0: return 0.0
  float(at) / float(a.time[step])

## The `.mcmeta` that sits beside a picture. Named here so nobody spells it
## twice.
proc metaPathOf*(texturePath: string): string = texturePath & ".mcmeta"
