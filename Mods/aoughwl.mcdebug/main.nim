## F3, and a debug screen whose lines are DATA.
##
## Minecraft's F3 overlay is a list in `DebugScreenOverlay.java`. Every line on
## it is a `String.format` written into that file. It is a wonderful screen and
## it is closed: adding a line means editing the game, and a mod that knows
## something interesting has nowhere to put it.
##
## This is that screen with the list taken out of the source and put in a
## catalog. A mod that knows something publishes a row saying what it is, which
## column it goes in, where in that column, which translation key labels it and
## **which service to ask for the value**. This mod reads the rows, sorts them,
## asks, and draws. It knows none of the lines.
##
## ## The one decision worth defending: why the value is a service
##
## A catalog is a noticeboard - append-only, read whenever the reader gets
## round to it. `ModSdk/services.nim` opens by saying that in its own words and
## that is the reason that module exists at all: a catalog is right for "here
## is what I contribute" and useless for "what is this worth right now". A
## debug screen is nothing but "right now".
##
## So the row is the declaration and the service is the value. The row is read
## once, when the catalog changes. The service is asked as often as the row
## says to. `aoughwl.voxel` publishes `voxel.chunk -> voxel.debug/chunk`,
## `aoughwl.hud` publishes its own, a mod nobody has written yet publishes
## a third, and **not one line of this file changes for any of them**. That is
## the test of the design, and it is why the value is not in the row.
##
## The alternative - a row whose value IS the number, rewritten every frame by
## its owner - was considered and is worse in the way that matters: it makes
## every publisher pay for a line whether or not anybody is looking at it. F3
## is off almost always. With a service, a screen that is down asks nothing,
## and that is not a thing this mod has to remember to do - it is what not
## calling a service means.
##
## ## This mod publishes NO lines, and that is deliberate
##
## Even the four things the host tells anybody - where the eye is, how big the
## window is, how fast frames are going by, which host this is - are published
## by a different mod. `ModSdk/services.nim` is the reason: **a mod cannot call
## its own service**, so a renderer that also published lines would have had to
## reach its own values by a path no other mod could use, and every claim below
## about the mechanism would then be untested for the case that matters. The
## split means every line on this screen, without exception, arrives the way a
## stranger's does. The test reads this file back and fails if it names any mod
## it draws - including the one that supplies its own default screen.
##
## ## What is data, and what is this file
##
## | data | here |
## | --- | --- |
## | which lines exist | the catalog they are published in |
## | which column, what order, on or off | the same row, and the override catalog over it |
## | how often each is refreshed | the same row |
## | the words of every label | the player's own language file, by key |
## | the shape of the screen itself | `screen.conf`, this mod's only data file |
## | the four numbers of the layout | `dbglayout`, and they are the game's |
## | asking, sorting, spreading the cost | `dbgpoll` and `dbgline` |
##
## What is left in this file is the host seam: the key, the screen size, the
## service calls and the drawing. Everything that can be wrong is next door and
## `Tests/mcdebug_test.exe` proves it in a millisecond over 1,800 windows.
##
## ## Cost, because this draws every frame
##
## Measured model: a host crossing is 0.68us plus 0.30us an argument, and an
## interpreted proc call is 2.1us.
##
##   * **Asking.** One `callService` per PROVIDER per frame, not per line
##     (`dbgpoll.asksFor`), and each line says how often it needs asking, with
##     the due ones spread across the period rather than landing together. A
##     vanilla screen is three providers and comes to about 30us a frame.
##   * **Drawing, host font.** A `fill` (8 arguments, 3.08us) and a `writeIn`
##     (11 arguments, 3.98us) a line. Thirty lines is 0.21ms.
##   * **Drawing, the pack's own bitmap font.** One `drawPicture` PER GLYPH, at
##     14 arguments and 4.88us each. Thirty lines of thirty characters is nine
##     hundred crossings and **4.4ms a frame**, which is a quarter of a 60Hz
##     frame spent drawing the screen that tells you where your frame went.
##
## So the font is a config field and the default is the host's. See
## `screen.conf`, which says the same thing where somebody changing it will
## read it. The pack font is the prettier screen and it is available and it costs
## that; what would make it free is a batched image call in the host surface,
## which does not exist and is written up in the report rather than invented
## here.
##
## ## Keys
##
## `F3` shows it and hides it again. That is all; the F3+letter combinations of
## the real game are debug ACTIONS rather than debug READOUT and belong to the
## mods that own the things they act on.

import jester
import input
import services
import importing
import textures
import aoughwl_mcui/mcuicore
import aoughwl_mcui/mcuiscale
import aoughwl_mcui/mcuifont
import aoughwl_mcui/mcuilang
import dbgline
import dbglayout
import dbgpoll

const
  Me = "aoughwl.mcdebug"
  Provider = "aoughwl.minecraft"
  GuiService = "minecraft.gui"

  LineKind = "aoughwl.debugline"
    ## The kind every mod that has something to say declares - and exactly one
    ## of them ever does, because it is declared only by whichever mod also
    ## creates the catalog below. See `ensureCatalog`.
  LineCatalog = "aoughwl.debug.lines"
    ## Where a mod says it has a line. Anybody may add to it.
  LayoutKind = "aoughwl.debuglayout"
    ## A kind of its own for the override catalog, so that neither catalog can
    ## be created without declaring a kind nobody else owns.
  LayoutCatalog = "aoughwl.debug.layout"
    ## Where a mod - or a modpack's own one-file mod - says where somebody
    ## else's line should go instead. A second catalog rather than a second
    ## kind of row in the first one, because they are contributed by different
    ## people for different reasons and the override has to be able to name a
    ## line whose publisher has not loaded yet.

  ConfFile = "screen.conf"
    ## The only data this mod ships: the SHAPE of the screen, not the lines on
    ## it. Its rows go into the override catalog, which is where a modpack puts
    ## its own.
  FontSheet = 128.0
  Ghost = 0.0039
    ## The alpha a line is announced at when it is set in the pack's bitmap
    ## font. A run of glyphs is a row of little textured quads and nothing that
    ## reads the screen rather than looking at it - a play script, anything
    ## assistive - can read a word out of that. So it is also asked for as an
    ## ordinary run of text at one step of alpha. The host-font path needs no
    ## such thing, because it already IS an ordinary run of text.

  PollPacks = 30
    ## Frames between asking `minecraft.gui` for the language and the font. It
    ## may load after this mod, may never load at all, and neither is an error.

var
  lines: seq[DebugLine] = @[]
  leftOrder: seq[int] = @[]
  rightOrder: seq[int] = @[]
  screen = defaultScreen()
  lang = noLang()
  advances: seq[int] = @[]
  showing = false
  frame = 0
  built = ""
    ## The two catalog signatures the current `lines` was built from. When
    ## either moves, the list is rebuilt - which is the whole of "a mod that
    ## loads later still gets its line on the screen".
  askedLang = false
  askedFont = false
  sinceAsk = 0
  toldName: seq[string] = @[]
  toldValue: seq[string] = @[]

proc say(text: string) = log("[mcdebug] " & text)

## One fact about this mod in the shape `expect state` reads, said when it
## changes rather than every frame.
proc tell(name, value: string) =
  var i = 0
  while i < toldName.len:
    if toldName[i] == name:
      if toldValue[i] == value: return
      toldValue[i] = value
      log("[assert] mcdebug." & name & "=" & value)
      return
    inc i
  toldName.add name
  toldValue.add value
  log("[assert] mcdebug." & name & "=" & value)

## The player's own word for a key, and the key itself when nothing translates
## it - which is what the game does, and is the only reason a bare `debug.xyz`
## will ever appear on this screen. There is no other way a word reaches it.
proc tr(key: string): string = translate(lang, key)

# ---------------------------------------------------------------------------
# The mod's own data file

## A file in this mod's own folder, as text.
##
## `readBytes` and not `modelBytes`. They look interchangeable and are not:
## `modelBytes` opens **only inside the proc answering a part or model
## request**, and the real host refuses it anywhere else - which the headless
## runner does not, so this read fine there and took the mod's `start()` down
## the first time it ran in the game. `importing` has its own byte door, open
## wherever this mod is and held to the same folder boundary by the same check.
proc readOwn(path: string): string =
  let handle = readBytes(path)
  if handle == 0: return ""
  result = textAt(handle, 0, byteCount(handle))
  closeBytes(handle)

# ---------------------------------------------------------------------------
# The catalogs
#
# The kind is declared here and the catalogs are created here only if nobody
# has yet, which is the rule `provideScheme` follows: the first mod to load
# owns them and every mod after it just adds. So a voxel world that loads
# before this mod publishes its lines into a catalog it made itself, and this
# mod finds them already there.

## A kind and its catalog, declared together or not at all.
##
## This shape is not tidiness, it is the fix for a real crash. A catalog KIND
## is owned by the mod that declares it and a second mod declaring the same id
## is REFUSED - `Collections.cs`, and the boot dies with
## `aoughwl.debugline is already owned by aoughwl.voxel`. Three mods
## in this pack contribute lines, any of them may load first, and every one of
## them has to be willing to be the one that makes the catalog.
##
## The first version of this asked "does the catalog exist" and then declared
## the kind if EITHER of two catalogs was missing, so a mod that found the
## lines catalog already there still tried to declare its kind on the way to
## making the layout one - and whichever mod loaded second took the boot down.
##
## So: one guard, one kind, one catalog, and no way to reach `defineCatalogKind`
## without also being the mod that creates the catalog it is for. The two
## catalogs here therefore have two kinds, which is honest anyway - a
## declaration and an override are not the same thing.
proc ensureCatalog(id, kind, kindNote, note: string) =
  if catalogSignature(id).len > 0: return
  defineCatalogKind(kind, "text", kindNote)
  createCatalog(id, kind, note)

proc ensureCatalogs() =
  ensureCatalog(LineCatalog, LineKind,
    "One line on a debug screen: where it goes and who to ask for it.",
    "What every mod has to say about itself, a line at a time.")
  ensureCatalog(LayoutCatalog, LayoutKind,
    "Where a line on a debug screen goes instead of where it said.",
    "Somebody else's idea of where a line goes.")

## Every declaration in the lines catalog, then every override in the layout
## catalog over it, then this mod's own settings out of the same overrides.
## Run when a signature moves and not per frame: it is a scan and a sort.
proc rebuild() =
  lines = @[]
  var i = 0
  let n = catalogCount(LineCatalog)
  while i < n:
    lines.add lineFrom(catalogItemId(LineCatalog, i),
      catalogItemProvider(LineCatalog, i), catalogText(LineCatalog, i))
    inc i
  var over = noConfig()
  i = 0
  let m = catalogCount(LayoutCatalog)
  while i < m:
    over.id.add catalogItemId(LayoutCatalog, i)
    over.row.add catalogText(LayoutCatalog, i)
    inc i
  applyTo(over, lines)
  screen = screenFrom(over, defaultScreen())
  leftOrder = ordered(lines, LeftSection)
  rightOrder = ordered(lines, RightSection)
  tell("lines", $lines.len)
  tell("left", $leftOrder.len)
  tell("right", $rightOrder.len)
  # Every line nobody can source, named in the log once. A gap on a debug
  # screen has to be findable from outside the screen.
  var missing = ""
  i = 0
  while i < lines.len:
    if not sourced(lines[i]) and lines[i].needs.len > 0:
      missing = missing & " " & lines[i].id & "(" & lines[i].needs & ")"
    inc i
  if missing.len > 0: say("no source for:" & missing)

## The default shape of the screen, out of this mod's own data file and into
## the override catalog - the same catalog a modpack contributes to, so that a
## pack's row lands after this one and wins. Not one of these rows is a LINE:
## this mod publishes none.
proc publishScreen() =
  let body = readOwn(ConfFile)
  if body.len == 0:
    say("no " & ConfFile & "; the screen keeps its built-in shape")
    return
  let conf = parseConfig(body)
  var r = 0
  while r < conf.id.len:
    addToCatalog(LayoutCatalog, conf.id[r], conf.row[r])
    inc r
  say($conf.id.len & " rows from " & ConfFile)

# ---------------------------------------------------------------------------
# The words and the letters

proc askLang() =
  if askedLang or not serves(GuiService): return
  var code = languageFrom(callService(GuiService, "language"))
  var table = callService(GuiService, "lang " & code)
  if table.len == 0 and code != "en_us":
    code = "en_us"
    table = callService(GuiService, "lang " & code)
  if table.len == 0: return
  askedLang = true
  lang = parseTable(table, code)
  tell("lang", code)

proc numbers(text: string): seq[int] =
  result = @[]
  var value = 0
  var digits = false
  var i = 0
  while i <= text.len:
    if i == text.len or text[i] == ' ':
      if digits: result.add value
      value = 0
      digits = false
    elif text[i] >= '0' and text[i] <= '9':
      value = value * 10 + (int(text[i]) - int('0'))
      digits = true
    inc i

proc askFont() =
  if askedFont or not serves(GuiService): return
  let line = callService(GuiService, "font")
  if line.len == 0: return
  let read = numbers(line)
  if read.len < 3: return
  askedFont = true
  var columns: seq[int] = @[]
  var i = 2
  while i < read.len:
    columns.add read[i]
    inc i
  advances = advancesFromColumns(columns, read[0])
  tell("advances", $advances.len)

## Whether the pack's own font is really available. Asked of the font and of
## the picture, never of a version or a name: a granted copy that answered for
## its advances and has no `font/ascii` published is a real state and it must
## cost the host font rather than a screen of nothing.
proc packFont(): bool =
  screen.font == PackFont and advances.len > 0 and
    hasPicture(Provider, "font/ascii")

# ---------------------------------------------------------------------------
# What each line says this frame

## The label of a line: the player's own word for its key, or the literal one
## the config gave it, or nothing at all for a line that is only a value. A
## key wins over a literal, so a config that adds a key to a line that had a
## literal starts translating without the literal having to be removed.
proc labelOf(line: DebugLine): string =
  if line.key.len > 0: return tr(line.key)
  line.label

proc textsFor(order: seq[int]): seq[string] =
  result = @[]
  let missing = tr(screen.missing)
  var i = 0
  while i < order.len:
    let line = lines[order[i]]
    if spacer(line): result.add ""
    else: result.add composed(line, labelOf(line), missing)
    inc i

## How wide a run comes out, in interface pixels, in whichever font is drawing.
## One crossing either way, and the pack font's answer needs none at all.
proc widthOf(text: string; pack: bool): int =
  if text.len == 0: return 0
  if pack and settable(text): return measure(text, advances)
  int(textWidth(text, float(LineHeight)) + 0.5)

proc widthsFor(texts: seq[string]; pack: bool): seq[int] =
  result = @[]
  var i = 0
  while i < texts.len:
    result.add widthOf(texts[i], pack)
    inc i

# ---------------------------------------------------------------------------
# Drawing
#
# From `update()` and not from `drawGui()`, which is not a style choice:
# `OnGUI` never runs without a game view, so a mod that draws its overlay there
# draws nothing at all in batch mode and nothing a headless capture or a play
# script can see. Drawing issued from `update` is recorded and replayed when a
# camera renders. `aoughwl.voxel` says the same thing over its own
# `paint()` for the same reason.

var scaleNow = 1

proc up(v: float): float = v * float(scaleNow)

proc drawPlate(r: DRect) =
  fill(up(r.x), up(r.y), up(r.w), up(r.h),
    PlateRed, PlateGreen, PlateBlue, PlateAlpha)

proc drawWithHost(run: Run) =
  writeIn(run.text, up(run.at.x), up(run.at.y), up(run.at.w), up(run.at.h),
    up(float(LineHeight)), "left", TextRed, TextGreen, TextBlue, 1.0)

## The same run set in the pack's own bitmap font. No drop shadow: the game's
## debug screen passes `false` where its menus pass `true`, so this is one pass
## and not two - and it is still one crossing a glyph, which is what the whole
## `font` setting exists to let a player decline.
proc drawWithPack(run: Run) =
  let glyphs = layout(run.text, advances, run.at.x, run.at.y)
  var i = 0
  while i < glyphs.len:
    let one = glyphs[i]
    inc i
    drawPicture(Provider, "font/ascii",
      up(one.dest.x), up(one.dest.y), up(one.dest.w), up(one.dest.h),
      one.src.x / FontSheet, one.src.y / FontSheet,
      (one.src.x + one.src.w) / FontSheet, (one.src.y + one.src.h) / FontSheet,
      TextRed, TextGreen, TextBlue, 1.0)
  # And the same words as an ordinary run at one step of alpha, so that
  # anything reading the screen rather than looking at it still finds them.
  writeIn(run.text, up(run.at.x), up(run.at.y), up(run.at.w), up(run.at.h),
    up(float(LineHeight)), "left", 1.0, 1.0, 1.0, Ghost)

proc drawColumn(order: seq[int]; section: Section; guiW: int; pack: bool): int =
  let texts = textsFor(order)
  let widths = widthsFor(texts, pack)
  let runs = plan(texts, widths, section, guiW)
  var i = 0
  while i < runs.len:
    let run = runs[i]
    inc i
    if not run.blank:
      drawPlate(run.plate)
      if pack: drawWithPack(run)
      else: drawWithHost(run)
  runs.len

# ---------------------------------------------------------------------------
# The frame

## Everything due this frame, asked one question per provider.
proc poll() =
  let asks = asksFor(lines, frame)
  var i = 0
  while i < asks.len:
    let ask = asks[i]
    inc i
    if serves(ask.service):
      let answer = callService(ask.service, ask.argument)
      if answer.len == 0:
        let why = serviceProblem()
        if why.len > 0: say(ask.service & ": " & why)
      applyAnswer(lines, ask, answer)
  tell("asks", $crossings(asks))

proc start() =
  ensureCatalogs()
  publishScreen()
  # Read once here so that the config's own `screen on=` is what the screen
  # does the first time a player ever runs it; after that whichever way they
  # left it is what they get, because F3 is a switch and a switch that forgets
  # is a worse switch.
  built = catalogSignature(LineCatalog) & "/" & catalogSignature(LayoutCatalog)
  rebuild()
  showing = remember("showing", screen.on)
  tell("showing", $showing)
  say("F3 shows the debug screen; its lines come from " & LineCatalog)

proc update() =
  inc frame
  if pressed(F3):
    showing = not showing
    save("showing", showing)
    tell("showing", $showing)
    # Ask for the language on the frame the screen goes up rather than up to
    # thirty frames later, so the first thing a player sees is words and not a
    # column of translation keys settling into words.
    sinceAsk = PollPacks
  if not showing: return

  inc sinceAsk
  if sinceAsk >= PollPacks:
    sinceAsk = 0
    askLang()
    askFont()

  let signature = catalogSignature(LineCatalog) & "/" &
    catalogSignature(LayoutCatalog)
  if signature != built:
    built = signature
    rebuild()

  poll()

  let w = int(screenWidth())
  let h = int(screenHeight())
  if w <= 0 or h <= 0: return
  scaleNow = guiScale(w, h, AutoGuiScale)
  let guiW = guiWidth(w, scaleNow)
  let pack = packFont()
  let drawn = drawColumn(leftOrder, LeftSection, guiW, pack) +
    drawColumn(rightOrder, RightSection, guiW, pack)
  tell("drawn", $drawn)
  tell("answered", $answeredCount(lines))
  tell("scale", $scaleNow)
  var fontName = HostFont
  if pack: fontName = PackFont
  tell("font", fontName)

proc stop() = discard
