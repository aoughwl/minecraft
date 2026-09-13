## The screen before the menu: Minecraft's loading overlay, as arithmetic.
##
## Minecraft does not open on its title screen. It opens on a flat brand-red
## field with the studio logo in the middle of it and a thin white progress bar
## under that, and only when the bar fills does the title screen fade in. That
## screen is `LoadingOverlay`, and every number in it is derived from the
## window rather than picked:
##
##     d0 = min(width * 0.75, height) * 0.25     // a quarter of the smaller
##     i1 = d0 * 0.5                             // half-height of the logo
##     j1 = d0 * 4 * 0.5                         // half-width of the logo
##     logo at (width/2 - j1, height/2 - i1), 2*j1 by 2*i1
##     k1 = height * 0.8325                      // the bar's centre line
##     bar from (width/2 - j1, k1 - i1) to (width/2 + j1, k1 + i1)
##
## The logo is four times as wide as it is tall because the studio wordmark is,
## and the bar is exactly as wide as the logo, which is why the screen reads as
## one object and not as two. `0.8325` is the one number in it that is a taste
## and not a consequence, and it is Mojang's taste, so it is written down here
## rather than rounded to something tidier.
##
## The bar itself is five rectangles and not two - a one-pixel frame on all four
## sides, and the fill inset by two inside it:
##
##     fill(minX + 2, minY + 2, minX + 2 + ceil((maxX - minX - 4) * p), maxY - 2)
##     fill(minX + 1, minY,     maxX - 1, minY + 1)      // top
##     fill(minX + 1, maxY - 1, maxX - 1, maxY)          // bottom
##     fill(minX,     minY,     minX + 1, maxY)          // left
##     fill(maxX - 1, minY,     maxX,     maxY)          // right
##
## `ceil` and not `round`: one per cent of progress must show as *something*,
## because a bar that is still empty at one per cent is a bar that looks stuck.
##
## ## Why this screen is a mode and not a moment
##
## The complaint that brought this module about was two sentences, and the
## second one is the interesting one: *"when we change resource pack we should
## have it go to that screen for that change of resource pack loading"*. That is
## right, and it is also honest - re-reading the jar under a different pack
## genuinely takes as long as it took the first time, and a menu that froze for
## twenty seconds instead would be lying about what it was doing. So the loading
## screen is a screen you can be *sent to*, from the resource-pack screen, with
## somewhere to come back to. `mcuistack` owns the coming back; this owns what
## it looks like while you are there.
##
## ## What it says
##
## The steps. The screen this replaces reported each step of the import and the
## player said so; keeping the substance and changing only the skin is the whole
## brief. `stepLines` takes whatever the importer's own progress line says and
## the notice's own lines, and lays them under the bar. None of those strings
## are invented here - they are the importer's, which is data - and the two
## sentences that *are* ours go through `ours()` at the seam like every other.

import mcuicore

const
  BrandRed* = 239
  BrandGreen* = 50
  BrandBlue* = 61
    ## `LoadingOverlay.BRAND_BACKGROUND` is ARGB 255, 239, 50, 61. Not a red
    ## anybody would pick by eye, and it is the one that makes the screen
    ## recognisable from across a room.

  LogoAspect* = 4.0
    ## The wordmark is four times as wide as it is tall.
  LogoFraction* = 0.25
    ## Of `min(width * 0.75, height)`.
  WidthWeight* = 0.75
    ## A wide window is not allowed to make the logo as big as it is tall.
  # Keep both progress rows comfortably inside a windowed 720p client.  The
  # original vanilla position leaves the status below the captured viewport
  # once the interface scale is applied.
  BarCentreFraction* = 0.72
    ## Mojang's number, and the only one in the screen that is a taste.
  FrameThickness* = 1.0
  FillInset* = 2.0
  BarHalfHeight* = 5.0
    ## How tall half the bar is, in interface pixels, and it is a **fixed**
    ## number rather than a share of the logo.
    ##
    ## This is the bug the screen was reported with - *"the loading bar / text is
    ## placed wrong/malformed"* - and the reason it survived a test is worth
    ## writing down: the test asserted the bar was as wide as the logo, centred,
    ## under it and on the screen, and every one of those was true of a bar
    ## sixty interface pixels tall. It never asserted how tall. A bar as tall as
    ## the logo is wrong in two ways at once, and the second is the one that was
    ## reported: it eats the room under it, so the lines of text that go there
    ## had four pixels to live in.
    ##
    ## The two numbers above are the evidence for this one. A frame one pixel
    ## thick and a fill inset two around a box sixty pixels tall is not a design
    ## anybody drew; around a box ten pixels tall it is exactly Minecraft's
    ## loading bar. `FrameThickness` and `FillInset` were written for a bar of
    ## about this height and the height is what had drifted.

  MojangSheet* = 120.0
    ## What `gui/title/mojangstudios.png` counts as, whatever it measures. The
    ## file in both jars here is 512 by 512; the game blits it as 120 by 120,
    ## which is nominal in exactly the sense `mcuisprite` means.
  MojangBandWidth* = 120.0
  MojangBandHeight* = 60.0
    ## The sheet is two bands stacked: the **top** band is the left half of the
    ## wordmark and the **bottom** band is the right half, each two units wide
    ## for one tall. That was not taken from anybody's memory of the game - the
    ## file was read and its opaque pixels fall in four runs, two inside each
    ## band, and each band's content is twice as wide as it is tall, which is
    ## the arrangement and nothing else is.
  MojangSecondBand* = 60.0

  StepGap* = 4
    ## Interface pixels between the bar and the first line of step text.

type
  LoadPlan* = object
    ## Where everything on the loading screen goes, in interface pixels.
    logo*: MRect
    bar*: MRect        ## the frame's outer rectangle
    centre*: float     ## the horizontal middle, which every line is centred on

## Rounding away from zero for a fraction that is already positive, which is
## what `Mth.ceil` does to the bar's fill.
proc ceilf*(x: float): float =
  let whole = floorf(x)
  if whole == x: whole else: whole + 1.0

## The whole screen's geometry from the interface size alone. Nothing else is
## consulted, which is why a test can walk every window shape in a loop.
proc loadPlan*(guiW, guiH: int): LoadPlan =
  var smaller = float(guiW) * WidthWeight
  if float(guiH) < smaller: smaller = float(guiH)
  let d = smaller * LogoFraction
  let halfHigh = floorf(d * 0.5)
  let halfWide = floorf(d * LogoAspect * 0.5)
  let midX = floorf(float(guiW) * 0.5)
  let midY = floorf(float(guiH) * 0.5)
  let barY = floorf(float(guiH) * BarCentreFraction)
  LoadPlan(
    logo: mrect(midX - halfWide, midY - halfHigh, halfWide * 2.0,
                halfHigh * 2.0),
    bar: mrect(midX - halfWide, barY - BarHalfHeight, halfWide * 2.0,
               BarHalfHeight * 2.0),
    centre: midX)

## The five rectangles of the bar, in the game's own order: the fill first and
## then the frame over it, so a fill that overshoots by a pixel is covered
## rather than showing.
##
## `progress` is clamped here rather than at every call site, because the thing
## producing it is an importer's percentage and an importer that reports 101 per
## cent must cost a full bar and not a rectangle off the side of the screen.
proc barQuads*(bar: MRect; progress: float): seq[MRect] =
  var p = progress
  if p < 0.0: p = 0.0
  if p > 1.0: p = 1.0
  let minX = bar.x
  let minY = bar.y
  let maxX = bar.right
  let maxY = bar.bottom
  let run = ceilf((maxX - minX - FillInset * 2.0) * p)
  result = @[]
  if run > 0.0:
    result.add mrect(minX + FillInset, minY + FillInset, run,
                     maxY - FillInset - (minY + FillInset))
  result.add mrect(minX + FrameThickness, minY,
                   maxX - FrameThickness - (minX + FrameThickness),
                   FrameThickness)
  result.add mrect(minX + FrameThickness, maxY - FrameThickness,
                   maxX - FrameThickness - (minX + FrameThickness),
                   FrameThickness)
  result.add mrect(minX, minY, FrameThickness, maxY - minY)
  result.add mrect(maxX - FrameThickness, minY, FrameThickness, maxY - minY)

## The importer says `"37% reading the block models"`. This is the 0.37, and -1
## when the line does not begin with a percentage at all - which is a real case
## (`"looking for a Minecraft"`) and means the bar has nothing to say rather
## than that it is empty. A caller draws an empty frame for -1 and a sliding
## marker over it, because an empty bar and an unknown bar must not look the
## same.
proc loadFraction*(progress: string): float =
  var digits = 0
  var value = 0
  var i = 0
  while i < progress.len and progress[i] == ' ': inc i
  while i < progress.len and progress[i] >= '0' and progress[i] <= '9':
    value = value * 10 + (int(progress[i]) - int('0'))
    inc digits
    inc i
  if digits == 0: return -1.0
  if i >= progress.len or progress[i] != '%': return -1.0
  if value > 100: value = 100
  float(value) / 100.0

## What the percentage was of - `"37% reading the block models"` is reading the
## block models. Empty when the line carried no percentage, in which case the
## whole line is the note and the caller says so.
proc loadNote*(progress: string): string =
  if loadFraction(progress) < 0.0: return progress
  var i = 0
  while i < progress.len and progress[i] != '%': inc i
  inc i
  while i < progress.len and progress[i] == ' ': inc i
  while i < progress.len and progress[i] == ' ': inc i
  # New progress records carry `step/max` before the human-readable note.
  while i < progress.len and progress[i] != ' ': inc i
  while i < progress.len and progress[i] == ' ': inc i
  result = progress[i .. ^1]

proc loadStep*(progress: string): string =
  result = ""
  if loadFraction(progress) < 0.0: return ""
  var i = 0
  while i < progress.len and progress[i] != '%': inc i
  inc i
  while i < progress.len and progress[i] == ' ': inc i
  let start = i
  while i < progress.len and progress[i] != ' ': inc i
  if i > start: result = progress[start ..< i]

## An unknown-progress marker: which slice of the bar the barber-pole sits in at
## this moment. A third of the bar, sliding across it and back, so a screen with
## no percentage behind it still looks alive.
##
## Returned as a fraction of the bar's inner width - `@[start, width]` - so the
## caller multiplies by whatever the bar came out as.
proc pacerSpan*(seconds: float; period = 2.0): seq[float] =
  let width = 1.0 / 3.0
  var t = (seconds / period) - floorf(seconds / period)
  # There and back, so it never jumps at the wrap.
  if t > 0.5: t = 1.0 - t
  @[t * 2.0 * (1.0 - width), width]

# ---------------------------------------------------------------------------
# What is being loaded
#
# `mcuistack` sends the screen here for two different reasons, and they are not
# the same reason with a different word on it: one is the first read of a
# Minecraft that has never been read, and the other is re-reading one under a
# resource pack the player just chose. The second is a thing the player did on
# purpose thirty seconds ago and it must say so, or it looks like a crash.

type
  LoadReason* = enum
    FirstRead,   ## the import that happens once
    PackChange   ## the player changed a resource pack and this is the cost

## The one sentence at the top of the loading screen, as the caller's own words
## keyed by reason. Kept as a pair of *marks* rather than as the sentences
## themselves so that the test can assert the two are disjoint - the same
## assertion `mcuigrant` makes about its six states, and for the same reason:
## the failure mode is one sentence quietly covering both cases.
proc reasonMark*(r: LoadReason): string =
  if r == PackChange: "resource" else: "first"

## Every line under the bar, in order, from what the importer said. The notice's
## own lines come first because they are the ones with something to do in them;
## the percentage's note comes last because it changes every frame and a line
## that changes every frame at the top of a block makes the block unreadable.
proc stepLines*(notice: seq[string]; progress: string; room: int): seq[string] =
  result = @[]
  var i = 0
  while i < notice.len and result.len < room:
    result.add notice[i]
    inc i
  let note = loadNote(progress)
  if note.len > 0 and result.len < room:
    # Not equality: the notice own progress line is 37% reading the block
    # models and the note is the tail of it, so the two say the same thing and
    # only one of them belongs on the screen.
    var already = false
    var k = 0
    while k < result.len:
      let line = result[k]
      inc k
      var at = 0
      while at + note.len <= line.len:
        var c = 0
        while c < note.len and line[at + c] == note[c]:
          inc c
        if c == note.len:
          already = true
          at = line.len + 1
        else:
          inc at
    if not already: result.add note
  result

# ---------------------------------------------------------------------------
# The studio logo
#
# `gui/title/minecraft` is the *game's* wordmark and it is what this screen used
# to draw, because the importer did not publish the studio's. It does now:
# `assets/minecraft/textures/gui/title/mojangstudios.png` is in both jars on
# this machine, is published like every other interface picture, and is the
# player's own copy exactly as the dirt and the buttons are. Nothing of Mojang's
# ships here; when the player has not granted a Minecraft the screen falls back
# to whatever wordmark it has and, failing that, to no picture at all - a red
# field with a bar on it, which is honestly ours.

## The two halves of the logo on the screen, left then right.
proc logoHalves*(logo: MRect): seq[MRect] =
  let half = floorf(logo.w * 0.5)
  @[mrect(logo.x, logo.y, half, logo.h),
    mrect(logo.x + half, logo.y, logo.w - half, logo.h)]

## Which band of the sheet each of those halves reads from, in the sheet's own
## nominal pixels. `index` is 0 for the left half and 1 for the right.
proc logoBand*(index: int): MRect =
  if index == 0:
    return mrect(0.0, 0.0, MojangBandWidth, MojangBandHeight)
  mrect(0.0, MojangSecondBand, MojangBandWidth, MojangBandHeight)

## How much room is left under the bar for the lines that say what is loading.
## Spelled here rather than at the drawing so that the test can assert the text
## has somewhere to go, which is the half of the complaint the bar's height
## caused and the bar's height alone would not have proved.
proc stepRoom*(plan: LoadPlan; guiH, lineHeight: int): float =
  float(guiH) - (plan.bar.bottom + float(StepGap))

## The rectangle those lines occupy, for the one assertion that matters: that
## nothing on this screen sits on top of anything else on it.
proc stepBox*(plan: LoadPlan; guiH, lineHeight, lines: int): MRect =
  let top = plan.bar.bottom + float(StepGap)
  mrect(0.0, top, float(lineHeight * 4), float(lines * lineHeight))
