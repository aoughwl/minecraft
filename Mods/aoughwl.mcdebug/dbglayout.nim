## Where the lines go, which is four numbers out of the game's own code.
##
## `DebugScreenOverlay` lays both columns out with one loop, and it is short
## enough to quote:
##
##     int j = 9;                                   // the line height
##     int k = font.width(s);
##     int l = left ? 2 : guiScaledWidth - 2 - k;
##     int i1 = 2 + j * i;
##     fill(l - 1, i1 - 1, l + k + 1, i1 + j - 1, -1873784752);
##     drawString(font, s, l, i1, 14737632, false);
##
## Everything in this module is that. The left column starts two interface
## pixels in; the right column ENDS two interface pixels in, which is why it is
## the only part of the screen whose position depends on how wide the text came
## out. Each line is nine pixels below the last. Behind each is a plate one
## pixel proud of the text on three sides and flush with the next line on the
## fourth, so a column of them is a continuous strip and not a ladder. And the
## `false` on the end is no drop shadow - the menu's text has one and this does
## not, which halves what the screen costs to draw before anything else does.
##
## ## Why an empty line is still a line
##
## The loop skips drawing an empty string and still advances `i`, so a blank
## entry is a gap in the column rather than nothing at all. Minecraft uses that
## to separate the frame stats from the coordinates. A row here with nothing to
## say is the same thing, and `plan` keeps its slot.
##
## ## What this module is not allowed to know
##
## How wide a string is. That is the font's business and the font is data - a
## resource pack's `ascii.png` has its own advances and the whole of
## `mcuifont` exists to measure them. So `plan` takes the widths already
## measured, one per line, and the seam between the two is asserted rather than
## assumed.
##
## No host call, no font, no colour lookup: this is arithmetic, and
## `Tests/mcdebug_test.exe` runs it over 1,800 windows at every GUI scale.

import dbgline

type
  DRect* = object
    ## A rectangle of numbers, in interface pixels. Spelled here rather than
    ## borrowed from `mcuicore` because a pure module may import nothing but
    ## another pure module beside it - the rule that lets both of them be
    ## proved in a millisecond with no ModSdk on the path.
    x*, y*, w*, h*: float

  Run* = object
    text*: string
    at*: DRect
      ## Where the text starts, and how big it came out. `w` is the measured
      ## width and `h` is the line height, so a caller wanting to hit-test or
      ## to announce the line has the box without measuring anything again.
    plate*: DRect
      ## The translucent ground behind it.
    blank*: bool
      ## A slot with nothing in it. Drawn as nothing, and it still moves
      ## everything below it down - see above.
    line*: int
      ## Which line of the input this run came from, so a caller can get back
      ## to the row that produced it.

const
  Margin*: int = 2
    ## The game's inset from the edge of the interface, both columns.
  LineStride*: int = 9
    ## `font.lineHeight`: eight pixels of glyph and one of leading, which is
    ## also the distance from one line's top to the next's. Named for the
    ## stride rather than the height because `mcuifont` already exports a
    ## `LineStride` and a mod importing both would find the name ambiguous -
    ## which this toolchain reports as a type it cannot work out rather than
    ## as the clash it is.
  PlateInset*: int = 1
    ## How far the plate stands proud of the text, left, right and top. Not
    ## bottom: the plate is `LineStride` tall from one pixel above the text,
    ## so the plate of the next line starts exactly where this one ends.
  Separator*: string = ": "
    ## Punctuation between a label and its value, not a word. A config that
    ## wants something else puts it in the label.

  TextRed*: float = 0.9019607843137255
  TextGreen*: float = 0.9019607843137255
  TextBlue*: float = 0.9019607843137255
    ## 14737632 is 0xE0E0E0.
  PlateRed*: float = 0.3137254901960784
  PlateGreen*: float = 0.3137254901960784
  PlateBlue*: float = 0.3137254901960784
  PlateAlpha*: float = 0.5647058823529412
    ## -1873784752 is 0x90505050.

# ---------------------------------------------------------------------------
# What a line says

## The whole of one line, as one string: the label, the punctuation and the
## value. `label` is what the caller resolved out of the player's language file
## (or out of the config, or the key itself when nothing translated it) and
## `missing` is what a line with no source says instead of a number.
##
## The three cases are all different and all matter:
##
##   * nothing sources it            -> the label and `missing`
##   * something sources it and has
##     not answered yet              -> the label and `missing`
##   * something answered            -> the label and whatever it said, even
##                                      if that was nothing, because a
##                                      provider is allowed to say nothing
##
## A label with no value would render as a bare label, which reads like a
## number that happens to be blank. That is the one thing this screen must
## never do, and it is why `missing` has no default.
proc composed*(line: DebugLine; label, missing: string): string =
  var value = missing
  if sourced(line) and line.answered: value = line.value
  if label.len == 0: return value
  label & Separator & value

## A line with nothing to say at all - no label, no source. Minecraft's blank
## separator, said in this grammar.
proc spacer*(line: DebugLine): bool =
  line.key.len == 0 and line.label.len == 0 and not sourced(line) and
    line.needs.len == 0

# ---------------------------------------------------------------------------
# Where it goes

proc drect*(x, y, w, h: float): DRect = DRect(x: x, y: y, w: w, h: h)
proc right*(r: DRect): float = r.x + r.w
proc bottom*(r: DRect): float = r.y + r.h

## The column, laid out. One run per text, in the order given, at the game's
## four numbers. `widths` is one measured width per text and must be the same
## length; a caller that measured a different number of things has a bug and
## gets a shorter plan rather than a guess.
##
## `guiW` is only read for the right column, which is the whole difference
## between the two: the left one is anchored to an edge that does not move and
## the right one is anchored to an edge that does.
proc plan*(texts: seq[string]; widths: seq[int]; section: Section;
           guiW: int): seq[Run] =
  result = @[]
  var i = 0
  while i < texts.len and i < widths.len:
    let w = float(widths[i])
    var x = float(Margin)
    if section == RightSection: x = float(guiW - Margin) - w
    let y = float(Margin + LineStride * i)
    result.add Run(text: texts[i], line: i,
      at: drect(x, y, w, float(LineStride)),
      plate: drect(x - float(PlateInset), y - float(PlateInset),
        w + float(PlateInset * 2), float(LineStride)),
      blank: texts[i].len == 0)
    inc i

## How many lines fit above the bottom of the interface. Minecraft draws them
## all and lets them run off; this is here so a config CAN cap the screen and
## so the test can say what the cap would be, not because the mod applies one.
proc fitCount*(guiH: int): int =
  var n = (guiH - Margin) div LineStride
  if n < 0: n = 0
  n

## Whether every run in a plan is inside the interface horizontally. The right
## column's whole reason for existing is that this stays true as the text
## changes width, so it is the assertion the sweep is run for.
proc withinWidth*(runs: seq[Run]; guiW: int): bool =
  result = true
  var i = 0
  while i < runs.len:
    if not runs[i].blank:
      if runs[i].plate.x < 0.0: result = false
      if right(runs[i].plate) > float(guiW): result = false
    inc i

## The right edge every run of a right column shares. This is the invariant the
## column is anchored on and it does not depend on any text: two pixels in from
## the interface's own right edge, whatever is written.
proc rightEdge*(guiW: int): float = float(guiW - Margin)

## Whether the plates form one continuous strip - each starting exactly where
## the last ended, with no seam and no overlap. A one-pixel gap between them
## would read as a stripe and a one-pixel overlap would double the alpha, and
## both have to be impossible rather than unlikely.
proc continuous*(runs: seq[Run]): bool =
  result = true
  var i = 1
  while i < runs.len:
    if bottom(runs[i - 1].plate) != runs[i].plate.y: result = false
    inc i

# ---------------------------------------------------------------------------
# What the screen as a whole is set to
#
# Reserved config rows, so that the shape of the screen is data alongside the
# lines on it. `screen` is not a line id and can never be one, because a line
# id is namespaced by the mod that published it and this is not.

const
  ScreenRow*: string = "screen"
  PackFont*: string = "pack"
  HostFont*: string = "host"

type
  Screen* = object
    missing*: string
      ## The translation key shown where a line has no value. A key and not a
      ## sentence, so it comes out of the player's own language file like
      ## everything else, and shows as the key when nothing translates it -
      ## which is unmistakably not a number, which is the point.
    font*: string
      ## `host` or `pack`. See `dbgcost` in the test: the pack's bitmap font is
      ## one host crossing PER GLYPH and this screen is a thousand glyphs, so
      ## the default is the host's own text call and the pretty one is a choice
      ## the player makes knowing what it costs.
    on*: bool
      ## Whether the screen starts up shown. F3 toggles it either way.

proc defaultScreen*(): Screen =
  Screen(missing: "debug.unavailable", font: HostFont, on: false)

## The reserved rows out of the same config the lines came from.
proc screenFrom*(c: Config; base: Screen): Screen =
  result = base
  var r = 0
  while r < c.id.len:
    if c.id[r] == ScreenRow:
      result.missing = fieldOf(c.row[r], "missing", result.missing)
      result.font = fieldOf(c.row[r], "font", result.font)
      result.on = truth(fieldOf(c.row[r], "on", ""), result.on)
    inc r
