## Nine-slice, two-slice, and tiling: how a fixed piece of art becomes a widget
## of any size without any of it stretching.
##
## Minecraft's whole interface is a handful of sprites in `gui/widgets.png` and
## `gui/options_background.png`. A button is one 200 by 20 rectangle in that
## sheet and it has to serve a 200-wide menu button, a 98-wide half button and a
## 150-wide one. Stretching it would make the rounded corner wider on the wide
## one and the bevel a different thickness on the narrow one, which is precisely
## the tell of a clone. The corners must come out the same size every time.
##
## Two rules do that and Minecraft uses both, for different things.
##
## **The two-slice** is what a *button* really uses, and it is worth spelling
## out because "Minecraft uses nine-slice" is the thing everyone assumes and it
## is not what the button code does:
##
##     blit(x,          y, u,               v, w / 2, h);
##     blit(x + w / 2,  y, u + 200 - w / 2, v, w / 2, h);
##
## The left half of the button is the left half of the sprite and the right half
## is the *right* half of the sprite. Nothing is stretched and nothing is
## repeated - the sprite is simply overlapped with itself in the middle. It is
## exact for any width up to the sprite's own, which is every button Minecraft
## draws, and it is one quad cheaper than a nine-slice.
##
## **The nine-slice** is what everything with a genuine border uses - the
## tooltip frame, the newer widget sprites, anything asked for at a size the
## sprite cannot cover by overlap. Four corners at their own size, four edges
## repeated along their run, and a middle repeated in both directions.
##
## Both answer in `Quad`s and neither draws anything.
##
## ## The one number that must not move
##
## At an integer GUI scale of `s`, every quad either rule emits must read
## exactly `1/s` picture pixels per screen pixel. That is not a nicety, it is
## the definition: it is what makes the art land on whole pixels, and it is the
## single property that separates this from a stretch. `mcuicore.densityAt`
## reads it back off the quads and `Tests/mcui_test.exe` asserts it in all nine
## regions of a nine-slice and both halves of a two-slice, against a stretch
## that gets it wrong everywhere the widget is not its own natural size.

import mcuicore

const
  MaxQuads* = 4096
    ## A tiled background over a 4K screen at scale 1 is about eight thousand
    ## 32-pixel tiles, and a caller that asks for more than this has asked for
    ## something it did not mean. The list stops rather than growing without
    ## bound; the caller sees a short list, not a hang.

## One row of tiles along `run` screen pixels, each showing `srcW` picture
## pixels at `scale`, with the last one cut short rather than squashed.
proc tileRow(into: var seq[Quad]; x, y, run, height: float;
             sx, sy, srcW, srcH: float; scale: int) =
  if run <= 0.0 or height <= 0.0 or srcW <= 0.0: return
  let step = srcW * float(scale)
  var at = 0.0
  while at < run and into.len < MaxQuads:
    var wide = step
    if at + wide > run: wide = run - at
    into.add quad(mrect(x + at, y, wide, height),
                  mrect(sx, sy, wide / float(scale), srcH))
    at = at + step

## A rectangle of tiles, cut short at the right and the bottom.
proc tileArea(into: var seq[Quad]; x, y, runX, runY: float;
              sx, sy, srcW, srcH: float; scale: int) =
  if runX <= 0.0 or runY <= 0.0 or srcW <= 0.0 or srcH <= 0.0: return
  let stepY = srcH * float(scale)
  var down = 0.0
  while down < runY and into.len < MaxQuads:
    var tall = stepY
    if down + tall > runY: tall = runY - down
    tileRow(into, x, y + down, runX, tall, sx, sy, srcW, tall / float(scale), scale)
    down = down + stepY

## A whole sprite into a rectangle exactly its own size at this scale. The
## degenerate case, spelled out because it is the common one and because it is
## the case a stretch would also get right - which is why the test never asserts
## about it alone.
proc plain*(dest, src: MRect): seq[Quad] =
  @[quad(dest, src)]

## Nine-slice. `left/top/right/bottom` are the corner insets in *picture*
## pixels; `dest` and the scale are in screen pixels. `tile` repeats the edges
## and the middle, which is what a Minecraft background does; false stretches
## them, which is what a caller wants for a sprite whose middle is flat.
proc nineSlice*(dest, src: MRect; left, top, right, bottom, scale: int;
                tile = true): seq[Quad] =
  result = @[]
  let s = float(scale)
  let l = float(left) * s
  let t = float(top) * s
  let r = float(right) * s
  let b = float(bottom) * s
  # What is left for the middle after the corners have taken theirs. A widget
  # asked for smaller than its own corners has no middle at all, and the corners
  # keep their size and overlap - which is what Minecraft's own sliced sprites
  # do rather than shrinking the border.
  var midW = dest.w - l - r
  if midW < 0.0: midW = 0.0
  var midH = dest.h - t - b
  if midH < 0.0: midH = 0.0
  let msw = src.w - float(left) - float(right)
  let msh = src.h - float(top) - float(bottom)
  let x0 = dest.x
  let x1 = dest.x + l
  let x2 = dest.x + l + midW
  let y0 = dest.y
  let y1 = dest.y + t
  let y2 = dest.y + t + midH
  let u0 = src.x
  let u1 = src.x + float(left)
  let u2 = src.x + src.w - float(right)
  let v0 = src.y
  let v1 = src.y + float(top)
  let v2 = src.y + src.h - float(bottom)

  # The four corners, at their own size, always.
  result.add quad(mrect(x0, y0, l, t), mrect(u0, v0, float(left), float(top)))
  result.add quad(mrect(x2, y0, r, t), mrect(u2, v0, float(right), float(top)))
  result.add quad(mrect(x0, y2, l, b), mrect(u0, v2, float(left), float(bottom)))
  result.add quad(mrect(x2, y2, r, b), mrect(u2, v2, float(right), float(bottom)))

  if tile:
    tileRow(result, x1, y0, midW, t, u1, v0, msw, float(top), scale)
    tileRow(result, x1, y2, midW, b, u1, v2, msw, float(bottom), scale)
    tileArea(result, x0, y1, l, midH, u0, v1, float(left), msh, scale)
    tileArea(result, x2, y1, r, midH, u2, v1, float(right), msh, scale)
    tileArea(result, x1, y1, midW, midH, u1, v1, msw, msh, scale)
  else:
    if midW > 0.0:
      result.add quad(mrect(x1, y0, midW, t), mrect(u1, v0, msw, float(top)))
      result.add quad(mrect(x1, y2, midW, b), mrect(u1, v2, msw, float(bottom)))
    if midH > 0.0:
      result.add quad(mrect(x0, y1, l, midH), mrect(u0, v1, float(left), msh))
      result.add quad(mrect(x2, y1, r, midH), mrect(u2, v1, float(right), msh))
    if midW > 0.0 and midH > 0.0:
      result.add quad(mrect(x1, y1, midW, midH), mrect(u1, v1, msw, msh))

## The button rule: the left half of the sprite and the right half of the
## sprite, overlapping in the middle. Exact for any width up to the sprite's,
## and the only rule that reproduces a Minecraft button pixel for pixel.
##
## `dest.w` is expected to be a whole number of interface pixels at this scale;
## the split is made in interface pixels and then multiplied up, so an odd width
## puts the extra pixel on the right exactly as integer division does in the
## game.
proc twoSlice*(dest, src: MRect; scale: int): seq[Quad] =
  result = @[]
  let s = float(scale)
  let wide = int(dest.w / s + 0.5)
  if wide <= 0: return result
  let leftGui = wide div 2
  let rightGui = wide - leftGui
  if float(wide) > src.w:
    # Wider than the sprite: overlapping would leave a hole in the middle, so
    # fall back to the general rule rather than drawing a gap.
    return nineSlice(dest, src, leftGui, 0, rightGui, 0, scale, true)
  result.add quad(mrect(dest.x, dest.y, float(leftGui) * s, dest.h),
                  mrect(src.x, src.y, float(leftGui), src.h))
  result.add quad(mrect(dest.x + float(leftGui) * s, dest.y,
                        float(rightGui) * s, dest.h),
                  mrect(src.x + src.w - float(rightGui), src.y,
                        float(rightGui), src.h))

## A picture repeated across a whole area - the title screen's dirt. `tileGui`
## is how many interface pixels one repeat covers, which for Minecraft's
## background is 32 whatever the size of the picture behind it.
proc tiled*(dest, src: MRect; tileGui, scale: int): seq[Quad] =
  result = @[]
  if tileGui <= 0: return result
  let step = float(tileGui) * float(scale)
  var down = 0.0
  while down < dest.h and result.len < MaxQuads:
    var tall = step
    if down + tall > dest.h: tall = dest.h - down
    var across = 0.0
    while across < dest.w and result.len < MaxQuads:
      var wide = step
      if across + wide > dest.w: wide = dest.w - across
      result.add quad(mrect(dest.x + across, dest.y + down, wide, tall),
                      mrect(src.x, src.y, src.w * wide / step,
                            src.h * tall / step))
      across = across + step
    down = down + step
