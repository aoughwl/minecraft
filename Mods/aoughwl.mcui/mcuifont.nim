## Minecraft's font, which is most of the impression.
##
## Everything else on the title screen can be right and it will still not look
## like Minecraft if the words are set in the host's UI font. The font is a
## bitmap - `assets/minecraft/textures/font/ascii.png`, a 16 by 16 grid of
## cells, 8 by 8 pixels each in the vanilla sheet - and three things about how
## the game uses it are what the eye actually recognises.
##
## **The advance is measured, not fixed.** The sheet is a grid, so every cell is
## the same width, but almost no glyph fills its cell. The game reads the
## picture once at load and, for each of the 256 cells, walks columns from the
## right until it finds one with any opaque pixel in it. That column plus two is
## the advance: the glyph, plus one pixel of gap. So `i` advances 2 and `A`
## advances 6 out of the same 8-wide cell, and a line set at a fixed 8 - or at
## the host's own proportional font - is a different line. This is the single
## most visible thing in the whole mod.
##
##     for (l1 = cell - 1; l1 >= 0; --l1) { if (column l1 has any alpha) break; }
##     ++l1;
##     charWidth[i] = (int)(0.5 + l1 * 8.0 / cell) + 1;
##
## Space is the exception the game hard-codes: cell 32 is entirely transparent,
## so the rule would give it 1, and `renderCharAtPos` returns 4 for it instead.
##
## **The quad is narrower than the advance.** The game draws `charWidth - 1.01`
## pixels of the cell and then moves the pen `charWidth - 0.01`. The one pixel
## it does not draw is the gap. Drawing the whole cell instead would make every
## letter touch the next.
##
## **The shadow is one pixel down and right, in a quarter of the colour.** Not a
## blur, not black: each channel of the text colour is masked to `0xFC` and
## shifted right by two, so white text has a dark grey shadow and yellow splash
## text has a dark olive one. The offset is one *interface* pixel, which is
## `scale` screen pixels - a shadow offset by one screen pixel at scale 3 is the
## other classic tell of a clone.
##
## Nothing in this module calls a host or reads a file. The alpha grid comes
## from `aoughwl.minecraft`, which already owns the PNG reader, and arrives
## as a list of advances over the service boundary.

import mcuicore

const
  Cells* = 16
    ## The sheet is 16 by 16 cells whatever its pixel size, so a pack shipping a
    ## 256 by 256 ascii.png has 16-pixel cells and the same 256 glyphs.
  Glyphs* = Cells * Cells
  NominalCell* = 8.0
    ## What one cell is worth in interface pixels, whatever it measures in the
    ## picture. A high-resolution font pack is drawn at the same size as the
    ## vanilla one and simply looks less blocky, which is what a font pack is.
  SpaceAdvance* = 4
  LineHeight* = 9
    ## Eight pixels of glyph and one of leading, which is the number every
    ## Minecraft screen lays its rows out on.
  FallbackAdvance* = 6
    ## What a caller measures with before any font has arrived. Six is the
    ## advance of a capital letter in the vanilla sheet, so a layout done with
    ## it is close enough to place a panel and is replaced the moment the real
    ## widths turn up.

type
  Glyph* = object
    code*: int
    dest*: MRect   ## where it goes, in interface pixels, relative to the origin
    src*: MRect    ## where it comes from, in the picture's own pixels

## One cell's advance from the rightmost column in it that has any opaque pixel.
## `rightmost` is -1 for a cell with nothing in it at all.
##
## Spelled on its own because it is the rule, and because the test asserts it
## against advances it derives from a picture it builds itself rather than
## against numbers copied from anywhere.
proc glyphAdvance*(rightmost, cellWidth: int): int =
  if cellWidth <= 0: return 1
  let filled = rightmost + 1
  int(0.5 + float(filled) * NominalCell / float(cellWidth)) + 1

## The measurement, on its own: for each of the 256 cells, the rightmost column
## in it with any opaque pixel, or -1 for a cell with nothing in it.
##
## This half is split from the rule above on purpose. `aoughwl.minecraft`
## owns the PNG reader and the resource-pack layer stack, so it is the mod that
## can see the pixels, and what it hands over the service boundary is exactly
## this: 256 column numbers, which is a measurement of a picture and not an
## opinion about fonts. The *rule* - the rounding, the plus one for the gap, the
## four for a space - stays here, where the test is, and is applied to the
## columns whether they were measured here or over there. Neither side can drift
## because there is only one copy of the part that could be wrong.
proc rightmostColumns*(alpha: seq[int]; width, height: int): seq[int] =
  result = @[]
  if width <= 0 or height <= 0 or alpha.len < width * height:
    return result
  let cellW = width div Cells
  let cellH = height div Cells
  if cellW <= 0 or cellH <= 0: return result
  var i = 0
  while i < Glyphs:
    let col = i mod Cells
    let row = i div Cells
    var rightmost = -1
    var l = cellW - 1
    while l >= 0:
      var opaque = false
      var y = 0
      while y < cellH:
        if alpha[(row * cellH + y) * width + col * cellW + l] != 0:
          opaque = true
          y = cellH
        else:
          inc y
      if opaque:
        rightmost = l
        l = -1
      else:
        dec l
    result.add rightmost
    inc i

## The rule, applied to those columns.
proc advancesFromColumns*(rightmost: seq[int]; cellWidth: int): seq[int] =
  result = @[]
  var i = 0
  while i < rightmost.len:
    result.add glyphAdvance(rightmost[i], cellWidth)
    inc i
  # The one cell the measurement cannot answer for: an empty cell measures 1,
  # and the game returns 4 for a space regardless of what is in the picture.
  if result.len > 32: result[32] = SpaceAdvance

## Every cell's advance, read off an alpha channel. `alpha` is `width*height`
## values of 0..255 in reading order - the fourth channel of the decoded PNG,
## and the only channel this rule looks at.
proc advancesFromAlpha*(alpha: seq[int]; width, height: int): seq[int] =
  if width <= 0: return @[]
  advancesFromColumns(rightmostColumns(alpha, width, height), width div Cells)

## The advance of one code, from a table that may be short or missing.
proc advanceOf*(advances: seq[int]; code: int): int =
  if code == 32: return SpaceAdvance
  if code < 0 or code >= advances.len: return FallbackAdvance
  advances[code]

## Whether this run can be set in the bitmap sheet at all.
##
## The vanilla `ascii.png` holds one byte's worth of glyphs and the cells above
## 126 are a fixed Latin-1-ish page that no modern language file addresses; the
## game itself sets anything outside it from `unicode_page_*.png`, which is a
## second reader and a second sheet. So a run with a byte over 126 in it is
## handed to the host's own text call instead - the words are still the
## player's own language file's words, they are simply not set in the pack's
## font. `docs/MCUI.md` says so plainly rather than hiding it.
proc settable*(text: string): bool =
  var i = 0
  while i < text.len:
    let c = int(text[i])
    if c < 32 or c > 126: return false
    inc i
  true

## How wide that run comes out, in interface pixels.
proc measure*(text: string; advances: seq[int]): int =
  result = 0
  var i = 0
  while i < text.len:
    result = result + advanceOf(advances, int(text[i]))
    inc i

## The run, laid out. `cellPx` is how many picture pixels one cell measures -
## 8 for the vanilla sheet, 16 for a doubled font pack - and only the source
## rectangles change with it; the destination is always in interface pixels, so
## a font pack changes the sharpness and never the layout.
proc layout*(text: string; advances: seq[int]; x, y: float;
             cellPx = NominalCell): seq[Glyph] =
  result = @[]
  let factor = cellPx / NominalCell
  var pen = x
  var i = 0
  while i < text.len:
    let code = int(text[i])
    inc i
    let adv = advanceOf(advances, code)
    if code != 32:
      # The drawn part is the advance less its one pixel of gap. Drawing the
      # whole cell is what makes letters touch.
      let wide = float(adv) - 1.0
      if wide > 0.0:
        let col = float(code mod Cells)
        let row = float(code div Cells)
        result.add Glyph(code: code,
          dest: mrect(pen, y, wide, NominalCell),
          src: mrect(col * cellPx, row * cellPx, wide * factor,
                     NominalCell * factor))
    pen = pen + float(adv)

## The same run again, one interface pixel down and right: the shadow pass,
## which is drawn first so the text lands on top of it.
proc shadowed*(glyphs: seq[Glyph]): seq[Glyph] =
  result = @[]
  var i = 0
  while i < glyphs.len:
    let g = glyphs[i]
    result.add Glyph(code: g.code,
      dest: mrect(g.dest.x + 1.0, g.dest.y + 1.0, g.dest.w, g.dest.h),
      src: g.src)
    inc i

## One channel of the shadow's colour, from the same channel of the text's.
## `(c & 0xFC) >> 2` - a quarter, with the bottom two bits thrown away first,
## which is the mask the game applies to the whole packed colour at once.
proc shadowChannel*(c: int): int = (c and 0xFC) shr 2

## The same, for a channel already in 0..1 as every colour on this surface is.
proc shadowLevel*(c: float): float =
  var v = int(c * 255.0 + 0.5)
  if v < 0: v = 0
  if v > 255: v = 255
  float(shadowChannel(v)) / 255.0

## Where a run starts if it is to be centred on `at`. Whole interface pixels,
## because a run started on a half pixel is a run with a soft edge.
proc centredStart*(at: float; width: int): float =
  floorf(at - float(width) * 0.5)
