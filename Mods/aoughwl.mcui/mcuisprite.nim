## How a modern Minecraft sprite is allowed to be resized - which is data, not
## a constant, and that is the whole point of this module.
##
## Up to 1.20.1 a button was a rectangle in `gui/widgets.png` and the way to
## resize it was Minecraft's two-slice, written into the game. From 1.20.2 the
## sheet is gone: `gui/sprites/widget/button.png` is its own file, and beside it
## `button.png.mcmeta` says how it stretches.
##
##     {"gui": {"scaling": {"type": "nine_slice",
##                          "width": 200, "height": 20, "border": 3}}}
##
## **Read it; never assume it.** The 1.21.11 jar says the button's border is 3.
## Faithful 64x, over that same jar, says `{"left": 20, "top": 4, "right": 20,
## "bottom": 4}` for the same button. A pack next year may say something else
## again. Any number written into this file would be wrong for at least one of
## those and there would be no way to tell which - so there is no number in this
## file at all, and `Tests/mcui_test.exe` asserts that by drawing the same button
## twice, once with each real border, and requiring the results to differ.
##
## The numbers are **nominal**. `width` and `height` are what the sprite counts
## as rather than what the file measures: Faithful's button.png is 800 by 80 and
## declares 200 by 20. Everything here works in the nominal size and the drawing
## divides source rectangles by it, so a 4x pack needs no special case anywhere
## and a 64x one needs none either.
##
## The line parsed here is what `aoughwl.minecraft/mcgui.nim` makes out of
## the `.mcmeta` - it owns the JSON reader - and the two halves are asserted
## against each other on the real jar's file and the real pack's.

import mcuicore
import mcuinine

type
  ScaleKind* = enum
    StretchScaling,   ## the whole sprite over the whole rectangle
    NineScaling,      ## corners at their own size, edges and middle repeated
    TileScaling       ## repeated at its own size

  Scaling* = object
    kind*: ScaleKind
    width*, height*: int              ## nominal, not the file's own pixels
    left*, top*, right*, bottom*: int ## nominal, and only for NineScaling
    said*: bool
      ## Whether this came out of a `.mcmeta` at all. False means nothing said
      ## anything and the sprite is stretched, which is what the game does with
      ## a sprite it has no scaling for.

## What a sprite with nothing said about it does: stretch.
proc stretched*(width, height: int): Scaling =
  Scaling(kind: StretchScaling, width: width, height: height,
          left: 0, top: 0, right: 0, bottom: 0, said: false)

proc numbersIn(text: string; from0: int): seq[int] =
  result = @[]
  var value = 0
  var sign = 1
  var digits = false
  var i = from0
  while i <= text.len:
    if i == text.len or text[i] == ' ':
      if digits: result.add value * sign
      value = 0
      sign = 1
      digits = false
    elif text[i] == '-':
      sign = -1
    elif text[i] >= '0' and text[i] <= '9':
      value = value * 10 + (int(text[i]) - int('0'))
      digits = true
    inc i

proc starts(text, head: string): bool =
  if text.len < head.len: return false
  var i = 0
  while i < head.len:
    if text[i] != head[i]: return false
    inc i
  true

## `nine <w> <h> <l> <t> <r> <b>`, `tile <w> <h>`, `stretch`, or "" for a sprite
## whose `.mcmeta` said nothing about scaling. `width` and `height` fall back to
## what the caller believes the sprite is when the line does not say.
proc parseScaling*(line: string; width, height: int): Scaling =
  result = stretched(width, height)
  if line.len == 0: return result
  if starts(line, "nine"):
    let n = numbersIn(line, 4)
    if n.len < 6: return result
    result = Scaling(kind: NineScaling,
      width: (if n[0] > 0: n[0] else: width),
      height: (if n[1] > 0: n[1] else: height),
      left: n[2], top: n[3], right: n[4], bottom: n[5], said: true)
    return result
  if starts(line, "tile"):
    let n = numbersIn(line, 4)
    result = Scaling(kind: TileScaling,
      width: (if n.len > 0 and n[0] > 0: n[0] else: width),
      height: (if n.len > 1 and n[1] > 0: n[1] else: height),
      left: 0, top: 0, right: 0, bottom: 0, said: true)
    return result
  if starts(line, "stretch"):
    result.said = true
  result

## The sprite's own rectangle, in the nominal pixels every source coordinate on
## this side is spelled in.
proc source*(s: Scaling): MRect =
  mrect(0.0, 0.0, float(s.width), float(s.height))

## That sprite into that rectangle, however this sprite says it may be resized.
## `dest` and `scale` are screen pixels; the quads that come back are what the
## drawing calls take, and nothing here draws.
proc spriteQuads*(s: Scaling; dest: MRect; scale: int): seq[Quad] =
  if s.width <= 0 or s.height <= 0: return @[]
  let src = source(s)
  if s.kind == NineScaling:
    return nineSlice(dest, src, s.left, s.top, s.right, s.bottom, scale, true)
  if s.kind == TileScaling:
    result = @[]
    let stepX = float(s.width) * float(scale)
    let stepY = float(s.height) * float(scale)
    var down = 0.0
    while down < dest.h and result.len < MaxQuads:
      var tall = stepY
      if down + tall > dest.h: tall = dest.h - down
      var across = 0.0
      while across < dest.w and result.len < MaxQuads:
        var wide = stepX
        if across + wide > dest.w: wide = dest.w - across
        result.add quad(mrect(dest.x + across, dest.y + down, wide, tall),
                        mrect(0.0, 0.0, wide / float(scale),
                              tall / float(scale)))
        across = across + stepX
      down = down + stepY
    return result
  plain(dest, src)
