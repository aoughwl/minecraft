## Minecraft's main menu, drawn out of the player's own Minecraft.
##
## Entering the `minecraft` modpack lands here: the tiled dirt, the
## logo assembled the way the game assembles it, the button column at the
## coordinates the game puts it at, the yellow splash breathing on its shoulder,
## and every word of it read out of the player's own language file by its
## translation key. Singleplayer takes the curtain down and the voxel world -
## which has been generating behind it the whole time - is simply there.
##
## ## This mod ships nothing of Mojang's, and nothing that stands in for it
##
## Not one picture and not one English word. The pictures arrive as
## `published:aoughwl.minecraft/<name>` uris - a name resolved inside the
## importer's folder by the host, so no path crosses a mod boundary and the file
## behind the name is whatever the player's resource-pack stack answered with.
## The words arrive as a translation table over the `minecraft.gui` service and
## are addressed by key: `menu.singleplayer`, never "Singleplayer". A key with
## no translation behind it draws as the key, which is what the game does, and
## is the only reason you will ever see a bare `menu.singleplayer` on this
## screen - it means the language file is not there yet.
##
## With nothing granted, this draws a plainly-ours screen that says so and says
## how to grant one. It does not draw an approximation of Minecraft. A menu made
## of our own rectangles with the real keys on it is honest; a hand-drawn
## Minecraft is not, and it would also be the thing that stops anybody noticing
## the import never ran.
##
## ## Where the work is
##
## Almost none of it is here. `main.nim` is the host seam - the screen size, the
## pointer, the pictures, the service - and every rule that can be wrong lives
## in six modules beside it that call no host at all and are proved by
## `Tests/mcui_test.exe` in under a second:
##
##   `mcuicore.nim`   rectangles, quads, a sine, and reading a mapping back
##   `mcuiscale.nim`  the integer GUI scale, which is why it looks like Minecraft
##   `mcuinine.nim`   nine-slice, the button's two-slice, and tiling
##   `mcuifont.nim`   glyph advances, layout, and the one-pixel shadow
##   `mcuilang.nim`   the translation table, missing keys, and %s substitution
##   `mcuimenu.nim`   the title screen as two dozen integers
##
## ## Keys
##
## None. The menu is a pointer and a click, exactly as the game's is.

import jester
import desktop
import textures
import services
import importing
import window
import input
import sound
import mcuicore
import mcuiscale
import mcuinine
import mcuisprite
import mcuigrant
import mcuifont
import mcuilang
import mcuimenu
import mcuilist
import mcuiload
import mcuistack
import mcuitext
import mcuiworlds
import mcuipacks
import mcuiservers
import mcuiopts
import mcuikeys
import mcuipause
import render
import aoughwl_handoff/handoff

const
  Provider = "aoughwl.minecraft"
  StudioProvider = "aoughwl.mcui"
  StudioLogo = "gui/title/aoughwlstudios"
  EditionLogo = "gui/title/aoughwledition"
  GuiService = "minecraft.gui"

  WidgetsSheet = 256.0
    ## Every source rectangle in this mod is spelled in the *nominal* pixels of
    ## the vanilla sheet and divided by the nominal size on the way out, because
    ## a texture coordinate is a fraction. That is what makes a 512 by 512
    ## widgets.png out of a high-resolution pack land in exactly the same place:
    ## the mod never learns how big any picture is, and never needs to.
  LogoSheet = 256.0
    ## The *classic* logo sheet, 256 by 256, whose word is in two stacked bands.
    ## The modern one is 256 by 64 and holds the word whole; `mcuimenu` carries
    ## both rules and `layout` below decides which is drawn.
  EditionWidth = 142.0
    ## The Java Edition mark's box used to be 128 by 16, sized off Mojang's own
    ## 512 by 64 image. `aoughwledition.png` is the same 64 tall but 568 wide -
    ## a bit wider than the mark it replaces - so the box widens by the same
    ## ratio (568 / 512 * 128 = 142) rather than squishing the art to fit the
    ## old box.
  EditionHeight = 16.0
  FontSheet = 128.0
  DirtSheet = 16.0

  PollEvery = 12
    ## Frames between asking the importer whether it has anything yet. The
    ## importer may load after this mod, may still be extracting, and may never
    ## answer at all; none of those is an error and none of them is worth a
    ## service call every frame.

  Ghost = 0.0039
    ## The alpha a label is *announced* at, beside being drawn.
    ##
    ## A run of text set in the pack's bitmap font is a row of little textured
    ## quads. Nothing outside this mod can read a word out of that - not a
    ## screen reader, and not `tools/playtest.exe`, whose `click <label>` finds
    ## the on-screen text that reads a thing and clicks its middle. So every
    ## label is also asked for as an ordinary run of text, in the button's own
    ## rectangle, at one step of alpha: invisible on the screen, and there for
    ## anything that reads the screen rather than looking at it. Both the
    ## translated words and the key are announced, so a script can address a
    ## button by `menu.singleplayer` whatever language the player is in.

  Button = "gui/sprites/widget/button"
  ButtonHover = "gui/sprites/widget/button_highlighted"
  ButtonOff = "gui/sprites/widget/button_disabled"
  Widgets = "gui/widgets"

type
  Skin = enum
    NoSkin,      ## nothing granted; the plainly-ours screen
    PackSkin     ## the player's own pictures

  Layout = enum
    ## Which interface a granted install has, and it is asked rather than
    ## guessed. Up to 1.20.1 every widget was a rectangle in one
    ## `gui/widgets.png` and a button was resized by Minecraft's two-slice.
    ## From 1.20.2 that file does not exist at all: each widget is its own
    ## sprite under `gui/sprites/`, with a `.mcmeta` beside it saying how it may
    ## be stretched - a genuine nine-slice whose border is DATA and differs
    ## between the jar and a pack layered over it. Deciding this by version
    ## number would have been wrong on the first real install it met.
    NoLayout, ClassicLayout, ModernLayout

var
  stack = atBoot()
    ## Which screen is up, and what is under it. Nine of them now, so which one
    ## is showing is a stack and not a variable: `mcuistack` owns the rule and
    ## this owns the drawing of whatever it says.
  heardImporter = false
    ## Whether the importer has answered anything at all yet. Until it has, the
    ## loading screen stays up rather than letting the title flash past.
  skin = NoSkin
  playing = false
    ## Singleplayer has been taken and the curtain is down.
  handedOver = false
  lang = noLang()
  advances: seq[int] = @[]
  fontCell = 8
  splashes: seq[string] = @[]
  splash = ""
  version = ""
  packLabel = ""
  language = ""
  scaleSetting = AutoGuiScale
  scaleNow = 1
  guiW = 320
  guiH = 240
  clock = 0.0
  ticks = 0
  askedFont = false
  askedLang = false
  askedSplash = false
  askedTrim = false
  noticeHidden = false

  # Which of the pictures this screen wants really came out of the player's
  # copy. Asked one at a time and never assumed: a `published:` name that
  # nobody published throws on the way to `drawImage` - `hasPicture` is the
  # question that answers instead of failing - and a resource pack is other
  # people's data, so a pack with a `widgets.png` and no `options_background`
  # must cost a flat backdrop rather than the session.
  hasDirt = false
  hasLogo = false
  hasEdition = false
  hasStudio = false
    ## Whether the granted copy answered for the studio logo the game opens on.
    ## Asked of the picture and not of a version: an older jar has it under the
    ## same name and a pack may have replaced it, and neither is a number.
  hasHover = false
  hasDisabled = false
  hasPanorama = false
  hasOverlay = false
  layout = NoLayout
  notice = parseNotice("")
  toldState = ""
  buttonScaling = stretched(ButtonWidth, ButtonHeight)
  hoverScaling = stretched(ButtonWidth, ButtonHeight)
  offScaling = stretched(ButtonWidth, ButtonHeight)

# ---------------------------------------------------------------------------
# Saying what happened, in the shape `expect state` reads

var toldName: seq[string] = @[]
var toldValue: seq[string] = @[]

## One fact about this mod, in the shape `expect state` reads, said when it
## changes and not every frame - a line a frame is a log nobody can read.
proc tell(name, value: string) =
  var i = 0
  while i < toldName.len:
    if toldName[i] == name:
      if toldValue[i] == value: return
      toldValue[i] = value
      log("[assert] mcui." & name & "=" & value)
      return
    inc i
  toldName.add name
  toldValue.add value
  log("[assert] mcui." & name & "=" & value)

proc say(text: string) = log("[mcui] " & text)

# ---------------------------------------------------------------------------
# Words
#
# `tr` is the only way a word reaches the screen. There is no second one, and
# `Tests/mcui_test.exe` reads this file back and fails if a string literal ever
# reaches a drawing call without coming through here or through `ours`.

## The player's own word for that key, or the key when nothing translates it -
## which is what the game draws too.
proc tr(key: string): string = translate(lang, key)

## The same, with arguments, for the keys that carry `%s`.
proc trf(key: string; args: seq[string]): string = translate(lang, key, args)

## A sentence that is ours, said as ours.
##
## These exist only for the states where there is nothing to translate against -
## no Minecraft granted, none installed, one being read, or one whose resource
## pack was made for a different version. The words for those cannot come from a
## language file because the language file is inside the copy of Minecraft that
## is missing. They are not substitutes for Minecraft's words and they do not
## pretend to be translation keys; `mcuigrant.nim` writes them and every one of
## them goes through here on the way to the screen, so there is one door and the
## test can stand at it.
proc ours(text: string): string = text

# ---------------------------------------------------------------------------
# Asking the importer

proc numbers(text: string): seq[int] =
  result = @[]
  var value = 0
  var sign = 1
  var digits = false
  var i = 0
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

proc askFont() =
  if askedFont: return
  let line = callService(GuiService, "font")
  if line.len == 0: return
  let read = numbers(line)
  if read.len < 3: return
  askedFont = true
  fontCell = read[0]
  var columns: seq[int] = @[]
  var i = 2
  while i < read.len:
    columns.add read[i]
    inc i
  advances = advancesFromColumns(columns, fontCell)
  say("the font is " & $fontCell & " pixels a cell; " & $advances.len &
    " advances measured")
  tell("font", $advances.len)

# ---------------------------------------------------------------------------
# The language table, read a few rows a frame
#
# **This was the eight-second frozen window a player reported.** `Player.log`
# said `Mod 'aoughwl.mcui' spent 8278ms in one update()`, and the line
# before it was this mod saying it had read 8,123 translations. That is what
# reading them cost: 3.9 seconds on the far side of the service boundary
# building the flat table, and 4.5 on this side turning it into a lookup, both
# inside one update(), with nothing repainting for either of them.
#
# So neither side does it all at once any more. `aoughwl.minecraft` builds
# the table on its own update() and answers "" until it is whole; this reads
# what comes back a budget of rows at a time. The budget is a count and not a
# clock, because a mod cannot time itself - the host samples
# `jester_time` before the callback and it does not move while the
# callback runs - so the only honest signal is the frame that already went by,
# which is what `paceRows` is given. `aoughwl.spawner`'s `sources.pacePump`
# paces its catalog reader off the same one.
#
# A half-read table is not a broken menu. `translate` answers a key it has not
# reached yet with the key itself, which is what Minecraft draws for a missing
# key and what this mod already draws on a machine with no Minecraft on it - and
# the loading screen is up the whole time anyway.

const
  RowsPerPump = 24
    ## Rows folded in per update() when frames are healthy. 4.5 seconds over
    ## 8,123 rows is about half a millisecond a row, so two dozen is a third of
    ## a sixty-a-second frame and the adjustment below finds the rest.
  RowsPerPumpMost = 96
    ## And never more, however cheap the last frame looked: a long frame
    ## measured after the fact is a long frame the player has already seen.
  RowsPerPumpLeast = 6
    ## And never fewer, however slow: six rows an update still finishes.
    ## It does not, and `MostPumps` is why.
  MostPumps = 8
    ## However slow the frames get, the table is whole within this many more
    ## update()s.
    ##
    ## **The floor above was a floor on the wrong thing**, on both sides of this
    ## boundary and for the same reason. `deltaTime()` is the whole frame and
    ## not this mod's share of it, so a modpack with a voxel world meshing
    ## chunks behind the menu halves the budget on every update and never
    ## returns it: the climb back needs a frame under ten milliseconds and there
    ## is not going to be one. Six rows an update then finishes eight thousand
    ## of them some time next week. Measured on the provider's side of the same
    ## seam: 162 rows of 7,767 in sixty seconds.
    ##
    ## So the budget has a ceiling on how many more updates it may take, and is
    ## raised to whatever meets it. It costs nothing to be generous here - this
    ## only ever runs while the loading screen is up, where there is no game to
    ## keep smooth and the pacing's whole job is that the window still repaints.
  SlowFrameMs = 20
    ## Longer than a sixty-a-second frame: take less of the next one.
  FastFrameMs = 10
    ## Room to spare: take more.

var
  langWanted = ""
    ## Which code is being read. Settled once, by asking whether the install has
    ## a file for the player's own language *before* asking for the table -
    ## because an empty table now means "still being built", and reading that as
    ## "this language is missing" would fall back to en_us on the next frame,
    ## restart the build, and do it again for ever.
  langBody = ""
  langAt = 0
  langReading = false
  rowsPerPump = RowsPerPump
  pumpsLeft = MostPumps
    ## How many more update()s the rest of the body may take. Counted DOWN:
    ## dividing what is left by a constant every time converges on the end
    ## without reaching it, which is the shape the first attempt at this had.

## How many rows this update may fold in: what the frame before it suggested,
## raised to whatever finishes the body within `MostPumps` more updates.
##
## What is left is measured rather than guessed. The body is bytes and the
## budget is rows, and nothing here knows how many rows are in the rest of it -
## but the bytes already read and the rows they turned into give the average
## length of a row in THIS file, which is a better number than any constant
## would be and is exact by the end.
proc rowBudget(): int =
  result = rowsPerPump
  if pumpsLeft > 1: pumpsLeft = pumpsLeft - 1
  if count(lang) <= 0 or langAt <= 0: return
  let perRow = langAt div count(lang)
  if perRow <= 0: return
  let least = ((langBody.len - langAt) div perRow) div pumpsLeft + 1
  if result < least: result = least

proc paceRows(frameMs: int) =
  if frameMs > SlowFrameMs:
    rowsPerPump = rowsPerPump div 2
    if rowsPerPump < RowsPerPumpLeast: rowsPerPump = RowsPerPumpLeast
  elif frameMs < FastFrameMs:
    rowsPerPump = rowsPerPump + 8
    if rowsPerPump > RowsPerPumpMost: rowsPerPump = RowsPerPumpMost

proc askLang() =
  if askedLang: return
  # Not while anything is still being read. `haslang` is answered out of what
  # has been extracted so far, so "no" during an import means "not yet" and
  # believing it would settle for a menu of bare keys a second before the file
  # it wanted landed on disk. Every other state has whatever it is ever going
  # to have.
  if notice.state == Importing or notice.state == NotImported: return
  if not langReading:
    if langWanted.len == 0:
      var code = languageFrom(remember("lang", callService(GuiService, "language")))
      if code != "en_us" and callService(GuiService, "haslang " & code) != "yes":
        # The player asked for a language their install has no file for.
        # Minecraft falls back to en_us for every key it cannot find; falling
        # back for the whole file is the same thing said once.
        code = "en_us"
      langWanted = code
      if callService(GuiService, "haslang " & langWanted) != "yes":
        # Nothing granted has a language file at all - a machine with no
        # Minecraft on it, which is every machine in CI. The question is still
        # ANSWERED rather than left open: `lang <code>` answers "" both for a
        # table being built and for a file that does not exist, so a caller that
        # only waited would wait for ever. The menu then draws every label as
        # its own key, which is what the game draws for a key it cannot
        # translate and what this mod has always drawn here.
        askedLang = true
        language = ""
        lang = beginTable("")
        say("no language file in this install; every label is its own key")
        tell("lang", "none")
        tell("keys", "0")
        return
    let table = callService(GuiService, "lang " & langWanted)
    if table.len == 0: return
    langBody = table
    langAt = 0
    lang = beginTable(langWanted)
    langReading = true
    pumpsLeft = MostPumps
  addRows(lang, langBody, langAt, rowBudget())
  if langAt < langBody.len: return
  langReading = false
  langBody = ""
  askedLang = true
  language = langWanted
  save("lang", language)
  say($count(lang) & " translations from " & language)
  tell("lang", language)
  tell("keys", $count(lang))

proc askSplash() =
  # After the table and not beside it: the seed below is `count(lang)`, and a
  # count taken while the table is still being read would make a headless run
  # that asked twice get two different splashes.
  if askedSplash or not askedLang: return
  let body = callService(GuiService, "splashes")
  if body.len == 0: return
  askedSplash = true
  splashes = splashLines(body)
  if splashes.len > 0:
    # One seed for the session, so a headless run that asks twice is told the
    # same thing twice.
    splash = splashAt(splashes, int(gameTime() * 1000.0) + count(lang))
  say($splashes.len & " splashes")

proc askTrim() =
  if askedTrim: return
  version = callService(GuiService, "version")
  packLabel = callService(GuiService, "pack")
  if version.len > 0 or packLabel.len > 0: askedTrim = true
  # `1.20.1.jar` is a file name and the version is what is in front of `.jar`.
  var cut = version.len
  var i = 0
  while i + 3 < version.len:
    if version[i] == '.' and version[i + 1] == 'j' and version[i + 2] == 'a' and
       version[i + 3] == 'r':
      cut = i
    inc i
  var trimmed = ""
  i = 0
  while i < cut:
    trimmed.add version[i]
    inc i
  version = trimmed

## What the importer is doing, and therefore what this screen has to say about
## it. Asked every time round, not once: the answer changes as an import runs
## and the whole complaint this answers was a screen that said one thing for
## ever.
## Whether the words question has been answered - either the table is whole, or
## this install has no language file behind it and every label is honestly its
## own key. `askLang` latches `askedLang` in both cases, which is what makes
## this a question with an end.
##
## **This is what the loading screen waits for, and why.** Reading the table was
## paced across frames to kill an eight-and-a-half-second frozen window, and the
## provider answers "" until it is whole - so `translate` answers a key it has
## not reached yet with the key. Nothing was wrong with either half; what was
## wrong was that the title screen did not wait for them. The player read
## `menu.singleplayer` off their own front door, and the loading screen that
## should have been up for those frames got none at all, because the importer
## had nothing left to do and `arrive` took it down on the first poll.
##
## Holding the loading screen fixes both at once, and it is the option that
## costs nothing: the pacing stays exactly as measured, no label is ever drawn
## as a key that has words behind it, and the seconds the words take are spent
## on the screen Minecraft spends them on rather than on a menu that lies.
## Drawing nothing instead would have been a menu with blank buttons, which is
## the same wait with less to look at.
##
## The loading screen itself is safe to hold: every line on it is either the
## importer's own words or one of ours through `ours()`, and not one of them
## goes through `tr`.
proc wordsSettled(): bool =
  # Nobody is answering for Minecraft at all, so there is no table coming and
  # no frame of waiting would ever end. `poll` treats that the same way.
  if not serves(GuiService): return true
  if askedLang: return true
  # A jar that is there and has not been read is not a wait, it is a screen:
  # nothing is being extracted and nothing will be until the player asks for
  # it, and the sentence saying so lives on the title screen with the notice
  # under it. Holding the loading screen in front of that would be a bar that
  # never fills over a message nobody can read. `askLang` returns on the same
  # state for the same reason, so the two cannot disagree.
  notice.state == NotImported

proc askNotice() =
  notice = parseNotice(callService(GuiService, "notice"))
  heardImporter = true
  # The one rule that opens and closes the loading screen, and the only place
  # it is opened or closed. See `mcuistack.arrive`.
  #
  # Held until the words are in. `arrive` is edge-triggered on the importer
  # starting and stopping, and skipping it keeps the edge rather than losing it:
  # `wasImporting` is only ever moved by this call, so an import that finishes
  # while the table is still being read is still seen as having finished, on the
  # first frame this is allowed to run.
  if wordsSettled(): arrive(stack, notice.state)
  var word = "ready"
  if notice.state == NoGrant: word = "nogrant"
  elif notice.state == NoJar: word = "nojar"
  elif notice.state == Importing: word = "importing"
  elif notice.state == NotImported: word = "notimported"
  elif notice.state == PackMismatch: word = "mismatch"
  elif notice.state == UnknownGrant: word = "unknown"
  if word != toldState:
    toldState = word
    tell("grant", word)
    let lines = noticeLines(notice)
    var i = 0
    while i < lines.len:
      say(lines[i])
      inc i

proc poll() =
  inc ticks
  # Every frame while the loading screen is up, because the bar on it is the
  # importer's own percentage and a bar that moved twice a second would look
  # stuck. Every twelfth frame otherwise, which is what the rest of the menu
  # needs.
  if ticks mod PollEvery != 0 and here(stack) != LoadingPage and
     not langReading: return
  if not serves(GuiService):
    # Nobody is answering for Minecraft at all. That is its own kind of nothing
    # and it reads as "not granted", which is what a modpack without the
    # importer in it looks like from here. The loading screen still has to come
    # down: nothing is being read and nothing ever will be.
    heardImporter = true
    arrive(stack, UnknownGrant)
    return
  askNotice()
  if skin == PackSkin and askedFont and askedLang and askedSplash: return
  if skin == NoSkin and hasPicture(Provider, "font/ascii"):
    # Without a font there are no words, and without buttons there is no menu.
    # Which button, though, is the install's business: this asks the importer
    # what the granted files actually are and believes the answer.
    let said = callService(GuiService, "layout")
    if said == "modern" and hasPicture(Provider, Button):
      layout = ModernLayout
    elif said == "classic" and hasPicture(Provider, Widgets):
      layout = ClassicLayout
    elif hasPicture(Provider, Button):
      layout = ModernLayout
    elif hasPicture(Provider, Widgets):
      layout = ClassicLayout
    if layout != NoLayout:
      skin = PackSkin
      # Modern jars use the ordinary dirt block for the options backdrop;
      # older code looked for a nonexistent gui/options_background sprite.
      hasDirt = hasPicture(Provider, "block/dirt")
      hasLogo = hasPicture(Provider, "gui/title/minecraft")
      hasEdition = hasPicture(StudioProvider, EditionLogo)
      hasStudio = hasPicture(StudioProvider, StudioLogo)
      hasOverlay = hasPicture(Provider, "gui/title/panorama_overlay")
      hasPanorama = true
      var f = 0
      while f < PanoramaSides:
        if not hasPicture(Provider, "gui/title/panorama_" & $f):
          hasPanorama = false
        inc f
      if layout == ModernLayout:
        # Every sprite carries its own slicing and every one of them is read.
        # Nothing about a border is written down in this mod.
        hasHover = hasPicture(Provider, ButtonHover)
        hasDisabled = hasPicture(Provider, ButtonOff)
        buttonScaling = parseScaling(
          callService(GuiService, "sprite widget/button"),
          ButtonWidth, ButtonHeight)
        hoverScaling = parseScaling(
          callService(GuiService, "sprite widget/button_highlighted"),
          ButtonWidth, ButtonHeight)
        offScaling = parseScaling(
          callService(GuiService, "sprite widget/button_disabled"),
          ButtonWidth, ButtonHeight)
        say("the button slices " & $buttonScaling.left & "/" &
          $buttonScaling.top & "/" & $buttonScaling.right & "/" &
          $buttonScaling.bottom & " out of " & $buttonScaling.width & "x" &
          $buttonScaling.height & ", as its own .mcmeta says")
        tell("border", $buttonScaling.left)
      say("the player's own interface pictures are in place")
      tell("skin", "pack")
      tell("layout", if layout == ModernLayout: "modern" else: "classic")
  askFont()
  askLang()
  askSplash()
  askTrim()

# ---------------------------------------------------------------------------
# Drawing
#
# Everything below takes interface pixels and multiplies up by the scale on the
# way to the host, and nothing below decides a layout: the layout came out of
# `mcuimenu`, the slicing out of `mcuinine`, the letters out of `mcuifont`.

proc up(v: float): float = v * float(scaleNow)

proc onScreen(r: MRect): MRect =
  mrect(up(r.x), up(r.y), up(r.w), up(r.h))

proc drawQuads(name: string; quads: seq[Quad]; sheetW, sheetH: float;
               red, green, blue, alpha: float) =
  var i = 0
  while i < quads.len:
    let q = quads[i]
    inc i
    drawPicture(Provider, name, q.dest.x, q.dest.y, q.dest.w, q.dest.h,
      q.src.x / sheetW, q.src.y / sheetH,
      (q.src.x + q.src.w) / sheetW, (q.src.y + q.src.h) / sheetH,
      red, green, blue, alpha)

## How wide a run comes out, in interface pixels, in whichever font is drawing.
proc widthOf(text: string): int =
  if skin == PackSkin and settable(text): return measure(text, advances)
  int(textWidth(text, float(LineHeight)) / float(scaleNow) + 0.5)

## One run of text, at an interface-pixel origin, with the game's shadow.
proc setRun(text: string; at: MRect; red, green, blue: float) =
  if skin != PackSkin or not settable(text):
    # No sheet, or a run the sheet cannot hold. The words are still the player's
    # own; they are simply not set in the player's own font.
    var wide = screenWidth() - up(at.x)
    if wide < up(float(LineHeight)): wide = screenWidth()
    writeIn(text, up(at.x), up(at.y) - up(1.0), wide, up(float(LineHeight)),
      up(float(LineHeight)), "left", red, green, blue, 1.0)
    return
  let glyphs = layout(text, advances, at.x, at.y)
  # The shadow first, one interface pixel down and right, at a quarter of the
  # colour with its bottom two bits thrown away.
  var pass = 0
  while pass < 2:
    var list = glyphs
    var r = red
    var g = green
    var b = blue
    if pass == 0:
      list = shadowed(glyphs)
      r = shadowLevel(red)
      g = shadowLevel(green)
      b = shadowLevel(blue)
    var i = 0
    while i < list.len:
      let one = list[i]
      inc i
      drawPicture(Provider, "font/ascii",
        up(one.dest.x), up(one.dest.y), up(one.dest.w), up(one.dest.h),
        one.src.x / FontSheet, one.src.y / FontSheet,
        (one.src.x + one.src.w) / FontSheet,
        (one.src.y + one.src.h) / FontSheet,
        r, g, b, 1.0)
    inc pass

proc setCentred(text: string; centreX, y: float; red, green, blue: float) =
  setRun(text, mrect(centredStart(centreX, widthOf(text)), y, 0.0, 0.0),
    red, green, blue)

## Beside every drawn label, the same words as an ordinary run of text at one
## step of alpha - see `Ghost`. Both the words and the key, so a script may
## address a button in any language by the key it really is.
proc announce(text, key: string; within: MRect) =
  let box = onScreen(within)
  writeIn(text, box.x, box.y, box.w, box.h, up(float(LineHeight)), "centre",
    1.0, 1.0, 1.0, Ghost)
  if key.len > 0 and key != text:
    writeIn(key, box.x, box.y, box.w, box.h, up(float(LineHeight)), "centre",
      1.0, 1.0, 1.0, Ghost)

# ---------------------------------------------------------------------------
# The widgets

## One button, anywhere, in whichever skin is up. Eight screens want a button
## and only one of them has a `MenuButton`, so the rectangle is the argument and
## `drawButton` below is the one-line adapter for the title screen's column.
proc drawWidget(rect: MRect; key, label: string; enabled, hovered: bool) =
  let b = MenuButton(key: key, rect: rect, enabled: enabled)
  let dest = onScreen(b.rect)
  if skin == PackSkin and layout == ModernLayout:
    # One sprite a state, each sliced the way its own `.mcmeta` says. A pack
    # that ships only the plain one gets the plain one in all three states,
    # which is what the game does with a sprite it cannot find.
    var name = Button
    var how = buttonScaling
    if not b.enabled and hasDisabled:
      name = ButtonOff
      how = offScaling
    elif b.enabled and hovered and hasHover:
      name = ButtonHover
      how = hoverScaling
    drawQuads(name, spriteQuads(how, dest, scaleNow),
      float(how.width), float(how.height), 1.0, 1.0, 1.0, 1.0)
  elif skin == PackSkin:
    drawQuads(Widgets,
      twoSlice(dest, buttonSprite(stateOf(b.enabled, hovered)), scaleNow),
      WidgetsSheet, WidgetsSheet, 1.0, 1.0, 1.0, 1.0)
  else:
    # Ours, and it does not pretend otherwise: a flat slab and a border.
    var level = 0.22
    if not b.enabled: level = 0.12
    elif hovered: level = 0.34
    fill(dest.x, dest.y, dest.w, dest.h, level, level, level + 0.03, 1.0)
    outline(dest.x, dest.y, dest.w, dest.h, float(scaleNow),
      0.55, 0.55, 0.58, 1.0)
  var red = 1.0
  var green = 1.0
  var blue = 1.0
  if not b.enabled:
    red = 0.63
    green = 0.63
    blue = 0.63
  elif hovered:
    # Minecraft tints a hovered button's label buttery yellow: 0xFFFFA0.
    blue = 0.63
  setCentred(label, b.rect.x + b.rect.w * 0.5, labelBaseline(b.rect),
    red, green, blue)
  announce(label, b.key, b.rect)

proc drawButton(b: MenuButton; label: string; hovered: bool) =
  drawWidget(b.rect, b.key, label, b.enabled, hovered)

proc drawBackdrop(panorama = true) =
  let whole = mrect(0.0, 0.0, screenWidth(), screenHeight())
  if panorama and skin == PackSkin and hasPanorama:
    # The sky box, turning. Four faces cover the horizon and the window walks
    # round them; `mcuimenu.panoramaPieces` cuts it at each face boundary and
    # this draws the pieces. The source rectangles are already fractions, so the
    # size of the pictures behind them - 1 by 1 in a bare jar, 1024 by 1024 out
    # of Faithful - never reaches here.
    let pieces = panoramaPieces(guiW, guiH, clock * PanoramaTurnsPerSecond)
    var i = 0
    while i < pieces.len:
      let one = pieces[i]
      inc i
      let box = onScreen(one.dest)
      drawPicture(Provider, "gui/title/panorama_" & $one.face,
        box.x, box.y, box.w, box.h,
        one.src.x, one.src.y, one.src.x + one.src.w, one.src.y + one.src.h,
        PanoramaShade, PanoramaShade, PanoramaShade, 1.0)
    if hasOverlay:
      drawPicture(Provider, "gui/title/panorama_overlay",
        whole.x, whole.y, whole.w, whole.h, 0.0, 0.0, 1.0, 1.0,
        1.0, 1.0, 1.0, 1.0)
    return
  if skin == PackSkin and hasDirt:
    drawQuads("block/dirt",
      tiled(whole, mrect(0.0, 0.0, DirtSheet, DirtSheet), BackgroundTile,
            scaleNow),
      DirtSheet, DirtSheet,
      BackgroundShade, BackgroundShade, BackgroundShade, 1.0)
  else:
    fill(whole.x, whole.y, whole.w, whole.h, 0.06, 0.06, 0.08, 1.0)

proc drawLogo() =
  if skin != PackSkin or not hasLogo: return
  # Two sheets and two rules. The classic `minecraft.png` is 256 by 256 with the
  # word in two stacked 155-wide bands and is drawn as two blits side by side;
  # the modern one counts as 256 by 64 and holds the word whole. Drawing the
  # modern sheet with the old rule reads a quarter of the word, twice.
  var plan: seq[Quad] = @[]
  var sheetW = LogoSheet
  var sheetH = LogoSheet
  if layout == ModernLayout:
    plan = logoQuadsModern(guiW)
    sheetW = ModernLogoSheetW
    sheetH = ModernLogoSheetH
  else:
    plan = logoQuads(guiW, LogoSheet)
  var quads: seq[Quad] = @[]
  var i = 0
  while i < plan.len:
    quads.add quad(onScreen(plan[i].dest), plan[i].src)
    inc i
  drawQuads("gui/title/minecraft", quads, sheetW, sheetH, 1.0, 1.0, 1.0, 1.0)
  if skin == PackSkin and hasEdition:
    # The authored replacement for Mojang's Java Edition wordmark, drawn the
    # same way `drawLoading` draws `StudioLogo`: our own picture, our own
    # provider, no fallback to the jar's mark if it is missing. Complete image,
    # not a sprite-sheet half, hence the 0..1 UV.
    let edition = onScreen(mrect(float(guiW) * 0.5 - EditionWidth * 0.5, 76.0,
      EditionWidth, EditionHeight))
    drawPicture(StudioProvider, EditionLogo, edition.x, edition.y,
      edition.w, edition.h, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0)

## The splash, turned twenty degrees and breathing.
##
## The turn is done per glyph along a turned baseline rather than by turning the
## quads, because a recorded quad on this surface is axis aligned and there is
## no transform to give it - see the report. Every other part of it is the
## game's: the anchor off the logo's shoulder, the one-second sine, the shrink
## to fit, and the yellow.
proc drawSplash() =
  if skin != PackSkin or splash.len == 0: return
  let width = widthOf(splash)
  if width <= 0: return
  let size = splashScale(width, clock)
  let anchor = splashAnchor(guiW)
  var pen = -float(width) * 0.5
  var i = 0
  let radians = SplashTurn * Pi / 180.0
  let shear = sine(radians) / cosine(radians)
  while i < splash.len:
    var one = ""
    one.add splash[i]
    inc i
    let where = splashPlace(pen + float(widthOf(one)) * 0.5,
                            float(SplashRise), size)
    if settable(one):
      let glyphs = layout(one, advances, 0.0, 0.0)
      var g = 0
      while g < glyphs.len:
        let glyph = glyphs[g]
        let w = glyph.dest.w * size
        let h = glyph.dest.h * size
        let x = anchor.x + where.x
        let y = anchor.y + where.y
        # An axis-aligned draw call cannot rotate a quad, so shear each glyph
        # in horizontal slices. The baseline still follows the game's twenty
        # degree turn, and the glyph itself now leans with that turn instead
        # of remaining visibly upright.
        var pass = 0
        while pass < 2:
          let red = if pass == 0: shadowLevel(1.0) else: 1.0
          let green = if pass == 0: shadowLevel(1.0) else: 1.0
          let blue = if pass == 0: shadowLevel(0.0) else: 0.0
          var slice = 0
          const Slices = 4
          while slice < Slices:
            let sy0 = float(slice) / float(Slices)
            let sy1 = float(slice + 1) / float(Slices)
            let dy = sy0 * h
            let dh = (sy1 - sy0) * h
            let shift = shear * (dy + dh * 0.5 - h * 0.5)
            let shadow = if pass == 0: up(1.0) else: 0.0
            drawPicture(Provider, "font/ascii", up(x + shift + shadow),
              up(y + dy + shadow), up(w), up(dh),
              glyph.src.x / FontSheet,
              (glyph.src.y + glyph.src.h * sy0) / FontSheet,
              (glyph.src.x + glyph.src.w) / FontSheet,
              (glyph.src.y + glyph.src.h * sy1) / FontSheet,
              red, green, blue, 1.0)
            inc slice
          inc pass
        inc g
    else:
      setRun(one, mrect(anchor.x + where.x, anchor.y + where.y, 0.0, 0.0),
        1.0, 1.0, 0.0)
    pen = pen + float(widthOf(one))

# ---------------------------------------------------------------------------
# The screens

proc drawNotice() =
  ## What is wrong and what to do about it, where it cannot be missed.
  ##
  ## Six states, six messages, and the two that matter most - "you have granted
  ## nothing" and "you granted a folder with no Minecraft in it" - have nothing
  ## in common, because telling somebody to edit a file they have already edited
  ## is a dead end and so is telling them to install a game they have installed.
  ## `mcuigrant.noticeLines` decides what to say; this decides where it goes.
  ##
  ## It sits between the logo and the button column, so it covers neither: the
  ## player can read it and still take Singleplayer. The world runs without
  ## Minecraft and that is deliberate - what must not happen, and what did
  ## happen, is running without a word about it.
  let lines = noticeLines(notice)
  if lines.len == 0 or noticeHidden: return
  var shown: seq[string] = @[]
  var li = 0
  while li < lines.len:
    let source = ours(lines[li])
    var at = 0
    while at < source.len:
      let stop = min(at + 30, source.len)
      shown.add source[at .. stop - 1]
      at = stop
    inc li
  # Minecraft-style notification card in the lower-right: it stays out of the
  # logo/menu path and remains readable over the panorama.
  var top = float(guiH - 72)
  var room = 5
  var count = shown.len
  if count > room: count = room
  let high = float(count * 10 + 30)
  let cardW = min(240.0, float(guiW) - 16.0)
  let band = onScreen(mrect(float(guiW) - cardW - 10.0, top - 7.0, cardW, high))
  fill(band.x, band.y, band.w, band.h, 0.10, 0.07, 0.05, 0.94)
  fill(band.x + up(2.0), band.y + up(2.0), band.w - up(4.0), up(2.0), 0.65, 0.52, 0.32, 1.0)
  let left = float(guiW) - cardW + 2.0
  var y = top
  var i = 0
  while i < count:
    var red = 1.0
    var green = 0.85
    var blue = 0.35
    if i > 0:
      red = 0.88
      green = 0.88
      blue = 0.92
    setRun(shown[i], mrect(left, y, 0.0, 0.0), red * 0.82, green * 0.82, blue * 0.82)
    y = y + 10.0
    inc i
  let dismiss = mrect(float(guiW) - 92.0, top + float(count * 10) + 4.0, 76.0, 16.0)
  let at = pointerGui()
  drawWidget(dismiss, "notice.dismiss", "Dismiss", true, dismiss.holds(at.x, at.y))
  if clicked("left") and dismiss.holds(at.x, at.y): noticeHidden = true

proc drawCorners() =
  # No sentence of Mojang's: the version the player imported on the left, and
  # the pack that answered on the right. Both are the player's own data. The one
  # sentence of ours down here is the short form of whatever the band above is
  # saying, so that a state which has scrolled off the top is still readable.
  let status = statusLine(notice)
  let at = bottomLeft(guiH)
  if status.len > 0:
    setRun(ours(status), at, 0.95, 0.85, 0.45)
  elif version.len > 0:
    setRun(version, at, 1.0, 1.0, 1.0)
  if packLabel.len > 0:
    let at = bottomRight(guiW, guiH, widthOf(packLabel))
    setRun(packLabel, at, 1.0, 1.0, 1.0)

# ---------------------------------------------------------------------------
# What each screen keeps
#
# One block, because the screens share more than they differ: a list, a
# selection, a scroll, and a form. Nothing here decides anything - every rule
# is in a module beside this one that calls no host.

var
  worlds = noWorlds()
  form = newForm()
  worldsLoaded = false
  servers = noServers()
  serverForm = addForm("", "", true)
  editingServer = -1
  serversLoaded = false
  packChoice = noChoice()
  packWas: seq[string] = @[]
  packsAsked = false
  jarFormat = 0
  frameCap = 0
  loadingCap = false
  grantPicking = false
  grantPath = ""
  caretTicks = 0
  netTold = ""
  # ---- the settings screens, and what is behind each control ------------
  storeAt: seq[string] = @[]
  storeIs: seq[int] = @[]
    ## Every setting's value, keyed by its `options.txt` name. Two parallel
    ## lists rather than a table, for the same reason everything else in this
    ## mod is two parallel lists: there is no table type on this side.
  optsLoaded = false
  optScroll = 0
  gripping = -1
    ## Which slider the pointer is dragging, as an index into the screen's own
    ## rows. -1 for none. A slider that only moved on the click would be a
    ## slider in name only.
  worldKey: seq[string] = @[]
  worldWhy: seq[string] = @[]
    ## What the world said about each `world:` setting: the empty string for
    ## `ok`, and its own sentence otherwise.
  worldAsked = false
  binds = defaultBinds()
  bindsLoaded = false
  bindScroll = 0
  capturing = -1
    ## Which row of `Bindings` is waiting for a key. -1 when none is, and the
    ## only state in this mod that swallows a keypress.
  languages: seq[string] = @[]
  langScroll = 0
  langListed = false

proc firstNumber(text: string): int =
  let read = numbers(text)
  if read.len == 0: 0 else: read[0]

proc linesOf(body: string): seq[string] =
  result = @[]
  var line = ""
  var i = 0
  while i <= body.len:
    if i == body.len or body[i] == '\n':
      if line.len > 0: result.add line
      line = ""
    else:
      if body[i] != '\r': line.add body[i]
    inc i

proc piecesOf(line: string; sep: char): seq[string] =
  result = @[]
  var piece = ""
  var i = 0
  while i <= line.len:
    if i == line.len or line[i] == sep:
      result.add piece
      piece = ""
    else:
      piece.add line[i]
    inc i

# ---------------------------------------------------------------------------
# The registries this mod keeps
#
# The host has `enterWorld(name)` and nothing that lists what has been entered,
# and it has no clock. So the world list is a thing this mod writes down. See
# the head of `mcuiworlds.nim` for why that is the honest shape rather than a
# shortcoming worked around.

proc loadWorlds() =
  if worldsLoaded: return
  worldsLoaded = true
  worlds.worlds = byRecency(readRegistry(remember("worlds", "")))
  tell("worlds", $worlds.worlds.len)

proc keepWorlds() =
  save("worlds", writeRegistry(worlds.worlds))
  tell("worlds", $worlds.worlds.len)

proc loadServers() =
  if serversLoaded: return
  serversLoaded = true
  servers.servers = readServers(remember("servers", ""))
  tell("servers", $servers.servers.len)

proc keepServers() =
  save("servers", writeServers(servers.servers))
  tell("servers", $servers.servers.len)

## The two columns, out of what the importer knows. `packs` answers one line a
## pack - name, its place in the selection, and what its own `pack.mcmeta` said
## - and `format` answers which pack format this jar speaks, which is the number
## the whole compatibility column is about.
proc askPacks(force = false) =
  if packsAsked and not force: return
  if not serves(GuiService): return
  packsAsked = true
  jarFormat = firstNumber(callService(GuiService, "format"))
  let rows = linesOf(callService(GuiService, "packs"))
  var entries: seq[PackEntry] = @[]
  var places: seq[int] = @[]
  var i = 0
  while i < rows.len:
    let f = piecesOf(rows[i], '\t')
    inc i
    if f.len < 5: continue
    entries.add PackEntry(name: f[0], description: unescapeValue(f[4]),
      lowest: firstNumber(f[2]), highest: firstNumber(f[3]), icon: false)
    places.add firstNumber(f[1])
  # `place` is 1 for the pack that wins and counts down the column, so the
  # selection is rebuilt by walking the places in order rather than by trusting
  # the order the folder listing happened to be in.
  var on: seq[string] = @[]
  var want = 1
  var guard = 0
  while guard <= entries.len:
    inc guard
    var k = 0
    while k < places.len:
      if places[k] == want: on.add entries[k].name
      inc k
    inc want
  packChoice = chooseFrom(entries, on)
  packWas = priorityOrder(packChoice)
  tell("packs", $entries.len)
  tell("packson", $packWas.len)

# ---------------------------------------------------------------------------
# The widgets the new screens need

## A row of text in the middle of the screen, at an interface-pixel baseline.
##
## `quiet` is for the one screen where the game gives its title and one of its
## buttons the same words - Create New World is `selectWorld.create` twice,
## which is Minecraft's own doing - and something reading the screen rather than
## looking at it would then find the title first and click a piece of text that
## does nothing. The title is drawn and not announced there; a title is not a
## thing anybody clicks, so nothing is lost and an ambiguity is.
proc drawTitle(key: string; top: int; quiet = false) =
  setCentred(tr(key), float(guiW) * 0.5, float(top), 1.0, 1.0, 1.0)
  if quiet: return
  announce(tr(key), key, mrect(0.0, float(top), float(guiW),
    float(LineHeight)))

## Minecraft's text field: a one-pixel light border, a black inside, the run
## four pixels in, and a caret that blinks. `key` is what a script addresses the
## field by; the text itself is the player's and is announced too.
proc drawField(r: MRect; f: Field; key: string) =
  let box = onScreen(r)
  let edge = up(1.0)
  fill(box.x - edge, box.y - edge, box.w + edge * 2.0, box.h + edge * 2.0,
    0.63, 0.63, 0.63, 1.0)
  fill(box.x, box.y, box.w, box.h, 0.0, 0.0, 0.0, 1.0)
  let baseline = floorf(r.y + (r.h - NominalCell) * 0.5)
  setRun(f.text, mrect(r.x + float(FieldTextInset), baseline, 0.0, 0.0),
    0.88, 0.88, 0.88)
  if caretShowing(caretTicks, f.focused):
    let ahead = float(widthOf(beforeCaret(f)))
    let at = onScreen(mrect(r.x + float(FieldTextInset) + ahead, baseline,
      1.0, NominalCell + 1.0))
    fill(at.x, at.y, at.w, at.h, 0.85, 0.85, 0.85, 1.0)
  announce(f.text, key, r)

## The band a list sits in, and its scrollbar. Minecraft darkens the dirt behind
## a list and draws a bar down the right of it when there is something to
## scroll; the bar is not drawn at all when there is not, which is how the
## screen says the list is complete.
proc drawListFrame(b: ListBox; scroll: int) =
  let backing = onScreen(mrect(float(b.left - 2), float(b.top),
    float(b.width + 4), float(b.bottom - b.top)))
  fill(backing.x, backing.y, backing.w, backing.h, 0.0, 0.0, 0.0, 0.35)
  if not scrollable(b): return
  let bar = onScreen(scrollbar(b))
  fill(bar.x, bar.y, bar.w, bar.h, 0.0, 0.0, 0.0, 0.6)
  let grip = onScreen(thumb(b, scroll))
  fill(grip.x, grip.y, grip.w, grip.h, 0.5, 0.5, 0.5, 1.0)
  fill(grip.x, grip.y, grip.w - up(1.0), grip.h - up(1.0),
    0.75, 0.75, 0.75, 1.0)

## One row of a list, outlined when it is the chosen one - which is what the
## game draws round a selected entry.
proc drawRowFrame(r: MRect; chosen: bool) =
  if not chosen: return
  let box = onScreen(r)
  outline(box.x, box.y, box.w, box.h, up(1.0), 1.0, 1.0, 1.0, 1.0)

## Which screen is up, in the shape `expect state` reads. Derived from the
## stack every frame rather than said at each place that changes it: the stack
## is the truth, and a `tell` beside every push was a second copy of it that
## could disagree - and did, the moment a screen was left by a rule rather than
## by a click.
proc screenWord(p: Page): string =
  if p == WorldsPage: "worlds"
  elif p == CreatePage: "create"
  elif p == ServersPage: "servers"
  elif p == AddServerPage: (if serverForm.keeping: "addserver" else: "direct")
  elif p == OptionsPage: "options"
  elif p == VideoPage: "video"
  elif p == ControlsPage: "controls"
  elif p == MousePage: "mouse"
  elif p == LanguagePage: "language"
  elif p == SoundPage: "sound"
  elif p == ChatPage: "chat"
  elif p == SkinPage: "skin"
  elif p == AccessPage: "accessibility"
  elif p == PacksPage: "packs"
  elif p == PausePage: "pause"
  elif p == LoadingPage: "loading"
  elif p == WorldPage: "world"
  else: "title"

proc pointerGui(): MRect =
  mrect(toGui(pointerX(), scaleNow), toGui(pointerY(), scaleNow), 0.0, 0.0)

proc notches(): int =
  if not wheelAvailable(): return 0
  let w = wheelY()
  if w > 0.5: 1
  elif w < -0.5: -1
  else: 0

# ---------------------------------------------------------------------------
# Typing
#
# `typed()` answers the letters the player pressed since the last frame, in
# their own keyboard layout; everything that is not a letter is a key. Both
# halves go through `mcuitext`, which owns the caret and calls nothing.

proc typeInto(f: var Field) =
  if not f.focused: return
  insert(f, typed())
  if pressed(Backspace): backspace(f)
  if pressed(Delete): deleteAhead(f)
  if pressed(LeftArrow): caretLeft(f)
  if pressed(RightArrow): caretRight(f)
  if pressed(Home): caretHome(f)
  if pressed(End): caretEnd(f)

# ---------------------------------------------------------------------------
# Going into a world

proc enterChosen(w: World; fresh: bool) =
  worlds.worlds = byRecency(visit(worlds.worlds, w.folder))
  keepWorlds()
  # The seed *is* the world. `aoughwl.voxel` reads this and makes the
  # terrain again from it; the amount carries the number, because that is the
  # field a handoff has for one.
  handOver("seed", w.folder, w.seed)
  if fresh: discard startFreshWorld(w.folder)
  else: discard enterWorld(w.folder)
  # Everything the player set before there was a world to set it on. Told again
  # here rather than only when the options screen is opened, because a render
  # distance chosen on the title screen has to be the render distance the world
  # comes up at - not the one it changes to the first time somebody goes back
  # into the menu.
  worldAsked = false
  playing = true
  stack.resetTo WorldPage
  handOver("world", "playing")
  handOver("pointer", "held")
  lockPointer()
  say("entering " & w.folder)
  # Said here and not derived in `drawGui`, because `drawGui` does not run
  # again: the menu is over.
  tell("screen", "world")
  tell("world", w.folder)
  tell("seed", $w.seed)

# ---------------------------------------------------------------------------
# The title screen

proc takeTitle(index: int; buttons: seq[MenuButton]) =
  let key = buttons[index].key
  if not buttons[index].enabled: return
  if key == KeySingleplayer:
    loadWorlds()
    stack.go WorldsPage
  elif key == KeyMultiplayer:
    loadServers()
    stack.go ServersPage
  elif key == KeyOptions:
    stack.go OptionsPage
  elif key == KeyQuit:
    say("quit")
    if windowAvailable(): windowClose()

proc drawGrantScreen() =
  let whole = mrect(0.0, 0.0, screenWidth(), screenHeight())
  if hasDirt:
    drawQuads("block/dirt",
      tiled(whole, mrect(0.0, 0.0, DirtSheet, DirtSheet), BackgroundTile,
        scaleNow), DirtSheet, DirtSheet,
      BackgroundShade, BackgroundShade, BackgroundShade, 1.0)
  else:
    fill(whole.x, whole.y, whole.w, whole.h, 0.10, 0.075, 0.055, 1.0)
  let panelW = min(float(guiW - 24), 360.0)
  let panelX = (float(guiW) - panelW) * 0.5
  let panelY = float(guiH) * 0.5 - 82.0
  let panel = onScreen(mrect(panelX - 8.0, panelY - 14.0, panelW + 16.0, 176.0))
  fill(panel.x, panel.y, panel.w, panel.h, 0.035, 0.035, 0.035, 0.92)
  outline(panel.x, panel.y, panel.w, panel.h, float(scaleNow),
    0.55, 0.55, 0.55, 1.0)
  let titleText = "Minecraft"
  let chooseText = "Choose your Minecraft folder to begin."
  let localText = "Your files stay on your computer."
  let addText = "Then add it to imports.txt:"
  let pathText = "minecraft = " & grantPath
  let clickText = "Choose the folder containing your Minecraft installation."
  setCentred(titleText, float(guiW) * 0.5, panelY, 1.0, 1.0, 1.0)
  setCentred(chooseText, float(guiW) * 0.5,
    panelY + 24.0, 0.92, 0.92, 0.92)
  setCentred(localText, float(guiW) * 0.5,
    panelY + 38.0, 0.72, 0.72, 0.72)
  if grantPath.len > 0:
    setCentred(addText, float(guiW) * 0.5,
      panelY + 55.0, 1.0, 0.85, 0.35)
    setCentred(pathText, float(guiW) * 0.5,
      panelY + 69.0, 0.85, 0.85, 0.85)
  else:
    setCentred(clickText, float(guiW) * 0.5,
      panelY + 55.0, 1.0, 0.85, 0.35)
  let grant = mrect(panelX + (panelW - 200.0) * 0.5, panelY + 88.0,
    200.0, 20.0)
  let quit = mrect(panelX + (panelW - 200.0) * 0.5, panelY + 114.0,
    200.0, 20.0)
  let at = pointerGui()
  drawWidget(grant, "grant.minecraft", "Choose Minecraft Folder...", true,
    grant.holds(at.x, at.y))
  drawWidget(quit, KeyQuit, "Quit", true, quit.holds(at.x, at.y))
  if not clicked("left"): return
  if quit.holds(at.x, at.y):
    if windowAvailable(): windowClose()
  elif grant.holds(at.x, at.y) and not grantPicking:
    if askFolder("Choose your Minecraft folder", importKnown("appdata")):
      grantPicking = true

proc grantUpdate() =
  if grantPicking and chosenReady():
    grantPicking = false
    if not chooseCancelled(): grantPath = filePath(chosenFile())

proc drawTitleScreen() =
  if skin == PackSkin and not askedFont: return
  let buttons = titleButtons(guiW, guiH)
  let at = pointerGui()
  let over = buttonUnder(buttons, at.x, at.y)
  var i = 0
  while i < buttons.len:
    drawButton(buttons[i], tr(buttons[i].key), i == over)
    inc i
  drawLogo()
  drawSplash()
  drawCorners()
  drawNotice()
  if over >= 0 and clicked("left"): takeTitle(over, buttons)

# ---------------------------------------------------------------------------
# The loading screen
#
# Mojang red, the wordmark in the middle, a white bar under it at
# `height * 0.8325`, and the importer's own steps beneath that. Every number is
# derived in `mcuiload` from the interface size; this only draws it.
#
# The logo is the studio's own - `gui/title/mojangstudios`, which the importer
# now publishes out of the granted jar like every other interface picture. It is
# two bands in one sheet, the top band the left half of the wordmark and the
# bottom band the right, and `mcuiload.logoBand` says which is which.
#
# When there is no Minecraft granted there is no such picture, and nothing here
# invents one: the screen falls back to the game's own wordmark if that is
# there, and to no picture at all if it is not. A red field with a bar on it is
# honestly ours; a mark drawn to look like somebody else's would not be.

proc drawLoading() =
  let whole = mrect(0.0, 0.0, screenWidth(), screenHeight())
  fill(whole.x, whole.y, whole.w, whole.h, float(BrandRed) / 255.0,
    float(BrandGreen) / 255.0, float(BrandBlue) / 255.0, 1.0)
  let plan = loadPlan(guiW, guiH)
  if hasStudio:
    # The authored replacement preserves the original sheet layout:
    # top band is the left half, bottom band is the right half.
    let halves = logoHalves(plan.logo)
    var band = 0
    while band < halves.len:
      var dest = onScreen(halves[band])
      # Let the two rasterized halves overlap by one GUI pixel at the join;
      # otherwise filtering can expose a hairline seam on some scales.
      if band == 0: dest.w = dest.w + up(1.0)
      elif band == 1:
        dest.x = dest.x - up(1.0)
        dest.w = dest.w + up(1.0)
      let src = logoBand(band)
      drawPicture(StudioProvider, StudioLogo, dest.x, dest.y, dest.w, dest.h,
        src.x / MojangSheet, src.y / MojangSheet,
        src.right / MojangSheet, src.bottom / MojangSheet,
        1.0, 1.0, 1.0, 1.0)
      inc band
  # There is deliberately no fallback logo here. The loading identity is
  # always Jester's authored mark; the Minecraft wordmark belongs only to the
  # title screen below.
  # Two Minecraft-style bars at the bottom, in GUI pixels so their labels use
  # the same bitmap font and scale as the rest of the interface.
  let barW = min(float(guiW - 24), 320.0)
  let barX = (float(guiW) - barW) * 0.5
  let overallGuiY = float(guiH - 52)
  let stepGuiY = overallGuiY + 25.0
  let overallY = up(overallGuiY)
  let stepY = up(stepGuiY)
  let sx0 = up(barX)
  let sw = up(barW)
  let sh = up(12.0)
  let overall = loadFraction(notice.progress)
  let inner = sw - up(4.0)
  let overallRun = if overall < 0.0: 0.0 else: inner * overall
  fill(sx0, overallY, sw, sh, 1.0, 1.0, 1.0, 1.0)
  fill(sx0 + 2.0, overallY + 2.0, inner, sh - 4.0, 0.08, 0.08, 0.08, 1.0)
  if overallRun > 0.0:
    fill(sx0 + 2.0, overallY + 2.0, overallRun, sh - 4.0, 1.0, 1.0, 1.0, 1.0)
  let step = loadStep(notice.progress)
  let knownSteps = step.len > 0 and step != "0/0"
  fill(sx0, stepY, sw, sh, 1.0, 1.0, 1.0, 1.0)
  fill(sx0 + 2.0, stepY + 2.0, inner, sh - 4.0, 0.08, 0.08, 0.08, 1.0)
  if knownSteps:
    var slash = 0
    while slash < step.len and step[slash] != '/': inc slash
    var current = 0
    var maximum = 0
    var n = 0
    while n < slash:
      if step[n] >= '0' and step[n] <= '9': current = current * 10 + int(step[n]) - int('0')
      inc n
    n = slash + 1
    while n < step.len:
      if step[n] >= '0' and step[n] <= '9': maximum = maximum * 10 + int(step[n]) - int('0')
      inc n
    if maximum > 0:
      var fillFraction = float(current) / float(maximum)
      if fillFraction < 0.0: fillFraction = 0.0
      if fillFraction > 1.0: fillFraction = 1.0
      fill(sx0 + 2.0, stepY + 2.0, inner * fillFraction, sh - 4.0,
        1.0, 1.0, 1.0, 1.0)
    setCentred(step, float(guiW) * 0.5, stepGuiY + 1.0, 1.0, 1.0, 1.0)
  else:
    let moving = pacerSpan(clock, 1.6)
    fill(sx0 + 2.0 + moving[0] * inner, stepY + 2.0,
      moving[1] * inner, sh - 4.0, 1.0, 1.0, 1.0, 1.0)
  let stepText = if loadNote(notice.progress).len > 0: loadNote(notice.progress)
    else: "locating Minecraft"
  let overallText = "Overall progress"
  let currentText = "Current step: " & stepText
  setRun(overallText, mrect(barX, overallGuiY - 12.0, 0.0, 0.0), 1.0, 1.0, 1.0)
  setRun(currentText, mrect(barX, stepGuiY - 12.0, 0.0, 0.0), 1.0, 1.0, 1.0)
  if overall >= 0.0:
    setCentred($int(overall * 100.0) & "%", float(guiW) * 0.5,
      overallGuiY + 1.0, 1.0, 1.0, 1.0)

# ---------------------------------------------------------------------------
# The world list

proc drawWorlds() =
  loadWorlds()
  let box = worldBox(guiW, guiH, worlds.worlds.len)
  worlds.scroll = scrollByNotches(box, worlds.scroll, notches())
  let at = pointerGui()
  drawListFrame(box, worlds.scroll)
  drawTitle(KeyWorldsTitle, TitleBaseline)
  let seen = visible(box, worlds.scroll)
  var i = seen[0]
  while i < seen[1]:
    let row = rowRect(box, i, worlds.scroll)
    let w = worlds.worlds[i]
    drawRowFrame(row, i == worlds.pick)
    setRun(w.name, mrect(row.x + 2.0, row.y + 1.0, 0.0, 0.0), 1.0, 1.0, 1.0)
    setRun(w.folder, mrect(row.x + 2.0, row.y + 12.0, 0.0, 0.0),
      0.53, 0.53, 0.53)
    setRun(tr(modeKey(w.mode)), mrect(row.x + 2.0, row.y + 22.0, 0.0, 0.0),
      0.53, 0.53, 0.53)
    announce(w.name, w.folder, row)
    inc i
  if worlds.worlds.len == 0:
    let middle = float(box.top + (box.bottom - box.top) div 2)
    setCentred(tr(KeyEmpty), float(guiW) * 0.5, middle, 1.0, 1.0, 1.0)
    announce(tr(KeyEmpty), KeyEmpty,
      mrect(0.0, middle, float(guiW), float(LineHeight)))
  let buttons = worldFooter(guiW, guiH, worlds.pick >= 0)
  let over = footerUnder(buttons, at.x, at.y)
  i = 0
  while i < buttons.len:
    drawWidget(buttons[i].rect, buttons[i].key, tr(buttons[i].key),
      buttons[i].enabled, i == over)
    inc i
  if not clicked("left"): return
  let row = rowUnder(box, worlds.scroll, at.x, at.y)
  if row >= 0:
    worlds.pick = row
    return
  if over < 0: return
  let b = buttons[over]
  if not b.enabled: return
  if b.action == LeaveWorlds:
    stack.back()
  elif b.action == CreateWorld:
    form = newForm()
    stack.go CreatePage
  elif b.action == PlayWorld:
    enterChosen(worlds.worlds[worlds.pick], false)
  elif b.action == RecreateWorld or b.action == EditWorld:
    # Re-Create opens the create screen filled in with the world's own name and
    # seed, which is what the game does. Edit is the same screen here, because
    # a name is the only thing about a world this build owns that is not the
    # world itself - and a rename is a new folder, so it is the same act.
    let w = worlds.worlds[worlds.pick]
    form = newForm(w.name, $w.seed)
    form.mode = w.mode
    stack.go CreatePage
  elif b.action == DeleteWorld:
    let w = worlds.worlds[worlds.pick]
    worlds.worlds = without(worlds.worlds, w.folder)
    worlds.pick = -1
    keepWorlds()
    say("deleted " & w.folder)

# ---------------------------------------------------------------------------
# Create New World

proc drawCreate() =
  let at = pointerGui()
  # The buttons first, and the title after them.
  #
  # Minecraft gives this screen's title and its confirm button the same words -
  # `selectWorld.create` twice - and with no pack granted every drawn run is
  # also an ordinary run of text. So something reading the screen rather than
  # looking at it finds whichever came first, and if that is the title it
  # clicks a heading and nothing happens. Drawing the button first makes the
  # thing that can be clicked the thing that is found. Nothing overlaps, so the
  # order costs nothing on the screen.
  let make = createRect(guiW, guiH)
  let leave = cancelRect(guiW, guiH)
  drawWidget(make, KeyCreate, tr(KeyCreate), true, make.holds(at.x, at.y))
  drawWidget(leave, KeyCancel, tr(KeyCancel), true, leave.holds(at.x, at.y))
  drawTitle(KeyCreate, TitleBaseline, true)
  setCentred(tr(KeyEnterName), float(guiW) * 0.5, float(NameLabelTop),
    0.63, 0.63, 0.63)
  drawField(nameRect(guiW), form.name, KeyEnterName)
  let folder = previewFolder(form, worlds.worlds)
  setCentred(trf(KeyResultFolder, @[folder]), float(guiW) * 0.5,
    float(FolderNoteTop), 0.53, 0.53, 0.53)
  setCentred(tr(KeyEnterSeed), float(guiW) * 0.5, float(SeedLabelTop),
    0.63, 0.63, 0.63)
  drawField(seedRect(guiW), form.seed, KeyEnterSeed)
  setCentred(tr(KeySeedInfo), float(guiW) * 0.5, float(SeedNoteTop),
    0.53, 0.53, 0.53)
  let mode = modeRect(guiW)
  drawWidget(mode, KeyGameMode,
    trf(KeyGenericValue, @[tr(KeyGameMode), tr(modeKey(form.mode))]),
    true, mode.holds(at.x, at.y))
  if pressed(Tab): nextField(form)
  typeInto(form.name)
  typeInto(form.seed)
  if pressed(Escape):
    stack.back()
    return
  if not clicked("left"): return
  let which = fieldUnder(guiW, at.x, at.y)
  if which == 0:
    focusName(form)
    return
  if which == 1:
    focusSeed(form)
    return
  if mode.holds(at.x, at.y):
    form.mode = nextMode(form.mode)
  elif leave.holds(at.x, at.y):
    stack.back()
  elif make.holds(at.x, at.y):
    # An empty seed box is a fresh world, and "fresh" has to come from
    # somewhere: the clock and the size of the list, which is different every
    # time and needs no host call that is not already here.
    let fallback = int(gameTime() * 1000.0) + worlds.worlds.len * 7919
    let made = newWorld(worlds.worlds, form.name.text,
      seedOf(form.seed.text, fallback), form.mode)
    var kept = worlds.worlds
    kept.add made
    worlds.worlds = byRecency(kept)
    worlds.pick = 0
    keepWorlds()
    stack.swapTo WorldsPage
    enterChosen(made, true)

# ---------------------------------------------------------------------------
# Resource packs

proc packRowLines(e: PackEntry): seq[string] =
  result = @[e.name]
  let f = fitness(e, jarFormat)
  if f == PackFits:
    result.add e.description
  else:
    # The warning takes the description's line, because a pack that will not
    # fit is the one thing about it worth a line.
    result.add "Incompatible " & (if f == PackOld: "Old" else: "New")

proc localizedPackLabel(key, fallback: string): string =
  let value = tr(key)
  if value == key or value.len == 0: fallback else: value

proc drawPackColumn(b: ListBox; which: seq[int]; scroll, pick: int) =
  drawListFrame(b, scroll)
  let seen = visible(b, scroll)
  var i = seen[0]
  while i < seen[1]:
    let row = rowRect(b, i, scroll)
    let e = packChoice.packs[which[i]]
    drawRowFrame(row, i == pick)
    let icon = onScreen(iconRect(row))
    fill(icon.x, icon.y, icon.w, icon.h, 0.16, 0.16, 0.18, 1.0)
    let lines = packRowLines(e)
    var red = 1.0
    var green = 1.0
    var blue = 1.0
    if fitness(e, jarFormat) != PackFits:
      green = 0.4
      blue = 0.4
    setRun(lines[0], mrect(textLeft(row), row.y + 1.0, 0.0, 0.0),
      1.0, 1.0, 1.0)
    setRun(lines[1], mrect(textLeft(row), row.y + 12.0, 0.0, 0.0),
      red, green, blue)
    announce(e.name, e.name, row)
    inc i

## Done. A selection that did not change costs nothing; one that did costs a
## re-import, and the loading screen is what that is spent in.
proc applyPacks() =
  if not changedFrom(packChoice, packWas):
    stack.back()
    return
  var argument = ""
  let want = priorityOrder(packChoice)
  var i = 0
  while i < want.len:
    if i > 0: argument.add "|"
    argument.add want[i]
    inc i
  discard callService(GuiService, "choose " & argument)
  packWas = want
  packsAsked = false
  say("resource packs chosen: " & $want.len)
  tell("packson", $want.len)
  # Back to the title, redrawn in the new pack's art, by way of the loading
  # screen - which is the whole of what was asked for.
  sendToLoading(stack, PackChange, TitlePage)

proc drawPacks() =
  askPacks()
  let left = availableBox(guiW, guiH, packChoice.available.len)
  let right = selectedBox(guiW, guiH, packChoice.selected.len)
  let turn = notches()
  packChoice.leftScroll = scrollByNotches(left, packChoice.leftScroll, turn)
  packChoice.rightScroll = scrollByNotches(right, packChoice.rightScroll, turn)
  let at = pointerGui()
  setCentred(localizedPackLabel(PackAvailable, "Available resource packs"), availableTitleAt(guiW).x, float(PackTitleTop),
    1.0, 1.0, 1.0)
  announce(localizedPackLabel(PackAvailable, "Available resource packs"), PackAvailable,
    mrect(float(left.left), float(PackTitleTop), float(left.width),
          float(LineHeight)))
  setCentred(localizedPackLabel(PackSelected, "Selected resource packs"), selectedTitleAt(guiW).x, float(PackTitleTop),
    1.0, 1.0, 1.0)
  announce(localizedPackLabel(PackSelected, "Selected resource packs"), PackSelected,
    mrect(float(right.left), float(PackTitleTop), float(right.width),
          float(LineHeight)))
  drawPackColumn(left, packChoice.available, packChoice.leftScroll,
    packChoice.leftPick)
  drawPackColumn(right, packChoice.selected, packChoice.rightScroll,
    packChoice.rightPick)
  let done = packDoneRect(guiW, guiH)
  let folder = packFolderRect(guiW, guiH)
  drawWidget(done, KeyDone, tr(KeyDone), true, done.holds(at.x, at.y))
  # Offered and refused: there is no way for a mod to open a folder on the
  # desktop from here, so the button says what it is and does not pretend.
  drawWidget(folder, PackFolderInfo, tr(PackFolderInfo), false,
    folder.holds(at.x, at.y))
  if pressed(Escape):
    applyPacks()
    return
  if not clicked("left"): return
  let onLeft = rowUnder(left, packChoice.leftScroll, at.x, at.y)
  if onLeft >= 0:
    # One click picks, a second one moves it - which is the click-twice half of
    # Minecraft's drag-or-click, and the half a mouse with no drag can do.
    if packChoice.leftPick == onLeft: enable(packChoice, onLeft)
    else: packChoice.leftPick = onLeft
    return
  let onRight = rowUnder(right, packChoice.rightScroll, at.x, at.y)
  if onRight >= 0:
    if packChoice.rightPick == onRight: disable(packChoice, onRight)
    else: packChoice.rightPick = onRight
    return
  if done.holds(at.x, at.y): applyPacks()

# ---------------------------------------------------------------------------
# Multiplayer

proc joinAt(address: string) =
  let host = hostOf(address)
  if host.len == 0: return
  say("joining " & address)
  if joinGame(host, portOf(address), "", myPeerName()):
    playing = true
    stack.resetTo WorldPage
    handOver("world", "playing")
    handOver("pointer", "held")
    lockPointer()
    netTold = ""
    tell("screen", "world")
  else:
    netTold = networkProblem()
    say("could not join " & address)
  tell("joined", if netTold.len == 0: "yes" else: "no")

proc drawServers() =
  loadServers()
  let box = serverBox(guiW, guiH, servers.servers.len)
  servers.scroll = scrollByNotches(box, servers.scroll, notches())
  let at = pointerGui()
  drawListFrame(box, servers.scroll)
  drawTitle(SrvTitle, TitleBaseline)
  let seen = visible(box, servers.scroll)
  var i = seen[0]
  while i < seen[1]:
    let row = rowRect(box, i, servers.scroll)
    let one = servers.servers[i]
    drawRowFrame(row, i == servers.pick)
    # `tr` on a name the player typed answers the name: a missing key draws as
    # the key, so the one server whose name really is a key - the default -
    # translates and every other one passes through.
    setRun(tr(one.name), mrect(row.x + 2.0, row.y + 1.0, 0.0, 0.0),
      1.0, 1.0, 1.0)
    setRun(one.address, mrect(row.x + 2.0, row.y + 12.0, 0.0, 0.0),
      0.53, 0.53, 0.53)
    # No ping, no player count, no message of the day: this transport has no
    # status handshake, and five green bars for a machine that is off would be
    # worse than saying nothing.
    setRun(tr(SrvUnknownStatus), mrect(row.x + 2.0, row.y + 22.0, 0.0, 0.0),
      0.53, 0.53, 0.53)
    announce(tr(one.name), one.address, row)
    inc i
  let buttons = serverFooter(guiW, guiH, servers.pick >= 0)
  let over = buttonUnder(buttons, at.x, at.y)
  i = 0
  while i < buttons.len:
    drawWidget(buttons[i].rect, buttons[i].key, tr(buttons[i].key),
      buttons[i].enabled, i == over)
    inc i
  if netTold.len > 0:
    setCentred(ours(netTold), float(guiW) * 0.5, float(guiH - 66),
      1.0, 0.45, 0.45)
  if not clicked("left"): return
  let row = rowUnder(box, servers.scroll, at.x, at.y)
  if row >= 0:
    servers.pick = row
    return
  if over < 0: return
  let b = buttons[over]
  if not b.enabled: return
  if b.action == LeaveServers:
    stack.back()
  elif b.action == AddServer:
    serverForm = addForm("", "", true)
    editingServer = -1
    stack.go AddServerPage
  elif b.action == DirectConnect:
    serverForm = addForm("", "", false)
    editingServer = -1
    stack.go AddServerPage
  elif b.action == EditServer:
    let one = servers.servers[servers.pick]
    serverForm = addForm(one.name, one.address, true)
    editingServer = servers.pick
    stack.go AddServerPage
  elif b.action == DeleteServer:
    servers.servers = withoutAt(servers.servers, servers.pick)
    servers.pick = -1
    keepServers()
  elif b.action == JoinServer:
    joinAt(servers.servers[servers.pick].address)

proc drawAddServer() =
  let at = pointerGui()
  let keeping = serverForm.keeping
  drawTitle(if keeping: SrvAddTitle else: SrvDirectTitle, TitleBaseline)
  if keeping:
    setCentred(tr(SrvEnterName), float(guiW) * 0.5, float(SrvNameLabelTop),
      0.63, 0.63, 0.63)
    drawField(serverNameRect(guiW), serverForm.name, SrvEnterName)
  setCentred(tr(SrvEnterIp), float(guiW) * 0.5,
    float(srvAddressLabelTop(keeping)), 0.63, 0.63, 0.63)
  drawField(addressRect(guiW, keeping), serverForm.address, SrvEnterIp)
  let accept = acceptRect(guiW, guiH)
  let leave = backRect(guiW, guiH)
  let acceptKey = if keeping: SrvAddButton else: SrvJoin
  drawWidget(accept, acceptKey, tr(acceptKey),
    connectable(serverForm.address.text), accept.holds(at.x, at.y))
  drawWidget(leave, SrvCancel, tr(SrvCancel), true, leave.holds(at.x, at.y))
  if pressed(Tab): nextField(serverForm)
  typeInto(serverForm.name)
  typeInto(serverForm.address)
  if pressed(Escape):
    stack.back()
    return
  if not clicked("left"): return
  let which = formFieldUnder(guiW, keeping, at.x, at.y)
  if which == 0:
    serverForm.onAddress = false
    serverForm.name.focused = true
    serverForm.address.focused = false
    return
  if which == 1:
    serverForm.onAddress = true
    serverForm.name.focused = false
    serverForm.address.focused = true
    return
  if leave.holds(at.x, at.y):
    stack.back()
  elif accept.holds(at.x, at.y) and connectable(serverForm.address.text):
    let one = Server(name: nameOrKey(serverForm),
      address: trimmed(serverForm.address.text),
      port: portOf(serverForm.address.text))
    if not keeping:
      stack.back()
      joinAt(one.address)
      return
    if editingServer >= 0:
      servers.servers = replacingAt(servers.servers, editingServer, one)
    else:
      servers.servers = withServer(servers.servers, one)
    keepServers()
    stack.back()

# ---------------------------------------------------------------------------
# Options
#
# Nine screens and about seventy controls, and almost none of the code for them
# is here. `mcuiopts` is the table - which control is on which screen, where it
# goes, what its value is called, and whether anything is behind it - and this
# is the seam: the store, the host calls, and the one service the world is told
# over.
#
# ## Where a value lives
#
# Under `save`/`remember`, keyed by the name the setting has in Minecraft's own
# `options.txt`: `mouseSensitivity`, `maxFps`, `renderDistance`. A row is keyed
# by its *store* and not by its place in the table, which matters because three
# settings are on two screens each - Auto-Jump is on Controls and on
# Accessibility, and the game keeps one value for it, not two.
#
# ## How a setting reaches the thing it moves
#
# Three ways, and the table says which:
#
#   * this mod does it, because it owns the thing - the GUI scale, the frame
#     cap, full screen, and the nine mixer buses;
#   * the world does it, over `voxel.settings`, which answers `ok` or
#     `no <reason>` a line - and the reason is what the screen greys the row
#     with, so a setting that stops being reachable stops claiming to be
#     reachable without a list here to keep in step;
#   * nothing does, and the row carries the reason in the table.
#
# The second is the only interesting one. This mod does not know what the voxel
# world can do and must not guess: it asks, once per session and again whenever
# a world is entered, and believes the answer. A world that is not loaded at all
# serves nothing, and every `world:` row is then greyed saying so - which is
# honest, and is the state the title screen is in before anybody has pressed
# Singleplayer.

const
  WorldSettings = "voxel.settings"
    ## The service the world offers for exactly this. One call carries every
    ## setting and one reply carries every answer, which is the shape
    ## `minecraft.gui`'s `lang` already has and the reason neither is a call a
    ## frame.

proc storeIndex(name: string): int =
  result = -1
  var i = 0
  while i < storeAt.len:
    if storeAt[i] == name: return i
    inc i

proc valueOf(o: Option): int =
  let at = storeIndex(o.store)
  if at < 0: return o.fallback
  storeIs[at]

proc putValue(o: Option; value: int) =
  let at = storeIndex(o.store)
  if at < 0:
    storeAt.add o.store
    storeIs.add value
  else:
    storeIs[at] = value
  save(o.store, int64(value))

## Every setting's remembered value, read once. A row whose store nobody has
## ever written takes the table's own default, which is Minecraft's.
proc loadOptions() =
  if optsLoaded: return
  optsLoaded = true
  let rows = allRows()
  var i = 0
  while i < rows.len:
    let one = rows[i]
    inc i
    if one.store.len == 0: continue
    if storeIndex(one.store) >= 0: continue
    storeAt.add one.store
    storeIs.add int(remember(one.store, int64(one.fallback)))
  # Full screen is the one setting whose truth is not in the store: the window
  # is already in a mode, the host will answer honestly which, and a remembered
  # value that disagreed would draw *Fullscreen: Off* over a full-screen window.
  # The player ships as a borderless full-screen window, so a stored default of
  # Off would also quietly leave it on the first frame of every session.
  if windowAvailable():
    let at = storeIndex(KeyFullscreenStore)
    if at >= 0:
      if displayMode() == InWindow: storeIs[at] = 0
      else: storeIs[at] = 1
  tell("settings", $storeAt.len)

proc loadBinds() =
  if bindsLoaded: return
  bindsLoaded = true
  binds = readBinds(remember("keys", ""))
  tell("binds", $binds.to.len)

# ---- what the world was told, and what it said ----------------------------

proc worldReason(name: string): string =
  var i = 0
  while i < worldKey.len:
    if worldKey[i] == name: return worldWhy[i]
    inc i
  # Nothing was asked, because nothing was there to ask. Said as ours, because
  # there is no Minecraft key for "this build has no world in it".
  ours("no world is drawing yet, so nothing here has anything to change")

## The reason out of a `no <reason>`, or the whole line when it is not one.
##
## Whatever comes back is the *world's* words and not ours, so an answer in a
## shape this does not know is passed through rather than replaced: a reason
## nobody here understood is still a reason the player can read, and swapping it
## for one of ours would be this mod inventing an explanation for somebody
## else's refusal.
proc reasonIn(status: string): string =
  result = status
  if status.len < 3: return result
  if status[0] != 'n' or status[1] != 'o' or status[2] != ' ': return result
  result = ""
  var j = 3
  while j < status.len:
    result.add status[j]
    inc j

proc noteAnswer(name, status: string) =
  var why = ""
  if status != "ok": why = reasonIn(status)
  var i = 0
  while i < worldKey.len:
    if worldKey[i] == name:
      worldWhy[i] = why
      tell("world." & name, if why.len == 0: "ok" else: "no")
      return
    inc i
  worldKey.add name
  worldWhy.add why
  tell("world." & name, if why.len == 0: "ok" else: "no")

## Tell the world about some settings and write down what it said. `lines` is
## `<name> <value>` a row; the reply is `<name><TAB><status>` a row.
##
## This is the one place a setting crosses out of this mod, and it is named so
## that `Tests/mcui_test.exe` can find it: every `world:` row in the table is
## honoured here or nowhere.
proc applyToWorld(lines: string) =
  if lines.len == 0: return
  if not serves(WorldSettings):
    worldKey = @[]
    worldWhy = @[]
    return
  let reply = linesOf(callService(WorldSettings, lines))
  var i = 0
  while i < reply.len:
    let f = piecesOf(reply[i], '\t')
    inc i
    if f.len >= 2: noteAnswer(f[0], f[1])

## Everything the world is allowed an opinion about, in one call. Said when a
## world starts and when this screen is first opened, so that a row's greying is
## never older than the world it is about.
proc pushWorld() =
  var lines = ""
  let rows = allRows()
  var i = 0
  while i < rows.len:
    let one = rows[i]
    inc i
    let name = worldName(one.effect)
    if name.len == 0: continue
    lines.add name
    lines.add ' '
    lines.add $valueOf(one)
    lines.add '\n'
  var b = 0
  while b < Bindings.len:
    if bindingWired(b):
      let action = worldName(BindingWiring[b])
      if action.len > 0:
        lines.add "bind."
        lines.add action
        lines.add ' '
        lines.add boundTo(binds, b)
        lines.add '\n'
    inc b
  applyToWorld(lines)
  worldAsked = true

# ---- what this mod does itself --------------------------------------------

## The settings this mod owns. Every branch here is named in the table's own
## `effect` column and the test fails if one of them is not in this file.
proc applyHere(o: Option; value: int) =
  if o.key == KeyGuiScale:
    scaleSetting = value
    tell("guiscale", $scaleSetting)
    return
  if o.key == KeyFramerate:
    frameCap = frameCapFor(value)
    frameRate(frameCap)
    tell("framecap", $frameCap)
    return
  if o.key == KeyFullscreen:
    # `InWindow` with no size means "leave the size as it is", so coming out of
    # full screen gives back the window that was there rather than one this mod
    # picked a size for.
    if windowAvailable():
      if value != 0: displayMode(Borderless)
      else: displayMode(InWindow)
    tell("fullscreen", $value)
    return
  if isSoundRow(o.key):
    if soundAvailable(): busVolume(busOf(o.key), float(value) / 100.0)
    tell("bus." & busOf(o.key), $value)
    return

## Whether this mod can really honour a row it says it owns. The sound rows are
## the only ones with a state to be in: a machine with no audio device has the
## screen and no mixer behind it, and a volume slider on such a machine is
## exactly the control this whole module refuses to draw.
proc hereReason(o: Option): string =
  if isSoundRow(o.key) and not soundAvailable():
    return ours("there is no audio device: ") & soundProblem()
  if o.key == KeyFullscreen and not windowAvailable():
    return ours("there is no window to make full screen")
  ""

## Whether a row is live, and why not when it is not. One answer for all three
## of the table's cases, so that the drawing has one branch and not three.
proc refusal(o: Option): string =
  if o.reason.len > 0: return o.reason
  let name = worldName(o.effect)
  if name.len > 0: return worldReason(name)
  hereReason(o)

# ---- drawing one row ------------------------------------------------------

## The label a row carries: its own name and its value, joined by the player's
## own `options.generic_value` rather than by a colon typed here.
proc labelOf(o: Option; value: int): string =
  if o.kind == ScreenOption: return tr(o.key)
  let shown = shownValue(o, value)
  var text = shown.valueText
  if shown.valueKey.len > 0: text = tr(shown.valueKey)
  elif shown.valuePattern.len > 0: text = trf(shown.valuePattern, @[text])
  trf(shown.pattern, @[tr(o.key), text])

## A slider: the track, the knob over it, and the label over that. Minecraft
## draws the track as the button's *disabled* band and the knob as two 4-wide
## blits out of `widgets.png`, which is what `mcuiopts.knobQuads` answers.
proc drawSlider(o: Option; value: int; live, hovered: bool) =
  drawWidget(o.rect, o.key, "", false, false)
  if live and skin == PackSkin and layout == ClassicLayout:
    drawQuads(Widgets, knobQuads(o, value, hovered), WidgetsSheet,
      WidgetsSheet, 1.0, 1.0, 1.0, 1.0)
  elif live:
    # No classic sheet to take a knob out of. One of ours, plainly ours, in the
    # same place - a slider with no knob would be a slider nobody can aim.
    let quads = knobQuads(o, value, hovered)
    var i = 0
    while i < quads.len:
      let box = onScreen(quads[i].dest)
      inc i
      var level = 0.62
      if hovered: level = 0.82
      fill(box.x, box.y, box.w, box.h, level, level, level, 1.0)
  var red = 1.0
  var green = 1.0
  var blue = 1.0
  if not live:
    red = 0.63
    green = 0.63
    blue = 0.63
  let text = labelOf(o, value)
  setCentred(text, o.rect.x + o.rect.w * 0.5, labelBaseline(o.rect),
    red, green, blue)
  announce(text, o.key, o.rect)

## Why a row is refused, said where the player is looking.
##
## Minecraft has nowhere to put this, because Minecraft has no refused rows: a
## setting the game cannot honour is a setting the game does not have. So this
## is ours, and it is drawn the way the game draws an option's tooltip - under
## the pointer, on hover - and *announced* always, so that a headless run can
## read the reason for a control it can see is grey without a screenshot and
## without a person.
proc drawRefusal(o: Option; why: string; hovered: bool) =
  announce(ours(why), o.key & ".why", o.rect)
  if not hovered: return
  setCentred(ours(why), float(guiW) * 0.5, float(guiH - ReasonBaseline),
    0.66, 0.66, 0.66)

proc drawRow(o: Option; hovered: bool) =
  let why = refusal(o)
  let live = why.len == 0
  let value = valueOf(o)
  if o.kind == SliderOption: drawSlider(o, value, live, hovered and live)
  else: drawWidget(o.rect, o.key, labelOf(o, value), live, hovered and live)
  if not live: drawRefusal(o, why, hovered)

## What a click or a drag on a row does. Answers whether anything moved, which
## is what stops a refused row from being a row that silently swallows clicks.
proc takeRow(o: Option; at: MRect; dragged: bool): bool =
  if refusal(o).len > 0: return false
  if o.kind == ScreenOption:
    if dragged: return false
    let where = opensPage(o.effect)
    if where == PacksPage: askPacks(true)
    if where == LanguagePage: langListed = false
    stack.go where
    optScroll = 0
    return true
  if o.kind == SliderOption:
    let want = valueAt(o, at.x)
    if want == valueOf(o) and dragged: return false
    putValue(o, want)
    applyHere(o, want)
    let name = worldName(o.effect)
    if name.len > 0: applyToWorld(name & " " & $want & "\n")
    return true
  if dragged: return false
  let want = nextValue(o, valueOf(o))
  putValue(o, want)
  applyHere(o, want)
  let name = worldName(o.effect)
  if name.len > 0: applyToWorld(name & " " & $want & "\n")
  true

# ---- a whole screen -------------------------------------------------------

proc drawOptionsScreen(page: Page) =
  loadOptions()
  loadBinds()
  if not worldAsked and serves(WorldSettings): pushWorld()
  let at = pointerGui()
  let rows = options(page, guiW, guiH, playing, optScroll)
  drawTitle(titleKey(page), titleTop(page))
  var band = listBox(OptListTop, guiH - OptListBottom,
    guiW div 2 - GridLeft, WideWidth, OptListRow, optListRows(rows.len))
  if scrolls(page):
    optScroll = clampScroll(band, optScroll + notches() * -OptListRow)
    drawListFrame(band, optScroll)
  var over = -1
  var i = 0
  while i < rows.len:
    let one = rows[i]
    let on = one.rect.holds(at.x, at.y) and
      ((not scrolls(page)) or (at.y >= float(band.top) and
                               at.y < float(band.bottom)))
    if on: over = i
    if (not scrolls(page)) or
       (one.rect.bottom > float(band.top) and one.rect.y < float(band.bottom)):
      drawRow(one, on)
    inc i
  let done = doneRect(page, guiW, guiH)
  drawWidget(done, KeyDone, tr(KeyDone), true, done.holds(at.x, at.y))
  if pressed(Escape):
    gripping = -1
    stack.back()
    optScroll = 0
    return
  if gripping >= 0:
    # A slider the pointer took hold of keeps it until the button comes up,
    # even when the pointer has wandered off the row - which is what every
    # slider anybody has ever used does, and what a hit test done afresh every
    # frame would get wrong the moment the hand moved.
    if not held(LeftButton):
      gripping = -1
    elif gripping < rows.len:
      discard takeRow(rows[gripping], at, true)
    return
  if not clicked("left"): return
  if done.holds(at.x, at.y):
    stack.back()
    optScroll = 0
    return
  if over < 0: return
  if rows[over].kind == SliderOption and refusal(rows[over]).len == 0:
    gripping = over
  discard takeRow(rows[over], at, false)

# ---------------------------------------------------------------------------
# Controls, and rebinding a key
#
# The one screen with a keyboard on it. Everything about the list - which
# controls there are, which category each is under, what a key is called in the
# player's own language, and which of them really drive anything - is in
# `mcuikeys`; this is the drawing, the capture and the one service line a
# rebinding sends.
#
# ## Capturing
#
# Minecraft's rule, and it is not "read the next key": a click on a binding's
# button puts the screen into a state where the *next* key pressed becomes the
# binding, Escape clears the binding rather than cancelling, and the button
# draws its own label between angle brackets while it waits. That last part is
# the one people notice and it is why `capturing` is a row index rather than a
# flag - the button that is waiting has to be able to say so.
#
# There is no host call for "what key went down", so this asks each of them in
# turn - and only while a capture is open, which is the difference between a
# hundred host calls on one frame and a hundred host calls on every frame.

proc capturedName(): string =
  var i = 0
  while i < CaptureKeys.len:
    if pressed(CaptureKeys[i]): return CaptureKeys[i]
    inc i
  if clicked("left"): return MouseLeft
  if clicked("right"): return MouseRight
  if clicked("middle"): return MouseMiddle
  ""

proc keepBinds() =
  save("keys", writeBinds(binds))
  tell("binds", $binds.to.len)

## Tell the world about one rebinding, if the world is the thing that honours
## it. `bind.<action> <key>` is the line; everything else on this screen is a
## row that says why not.
proc sendBind(row: int) =
  let action = worldName(BindingWiring[row])
  if action.len == 0: return
  applyToWorld("bind." & action & " " & boundTo(binds, row) & "\n")

proc drawControlsScreen() =
  loadBinds()
  loadOptions()
  if not worldAsked and serves(WorldSettings): pushWorld()
  let at = pointerGui()
  drawTitle(KeyControlsTitle, ControlsTitleTop)
  # The two buttons over the list, which are ordinary table rows.
  var heads = options(ControlsPage, guiW, guiH, playing, 0)
  var i = 0
  var over = -1
  while i < heads.len:
    var one = heads[i]
    one.rect = mrect(float(guiW div 2 - ControlsGridLeft +
      (i mod 2) * ControlsColumnStep), float(ControlsTopRow),
      float(ControlsHalfWidth), float(RowHeight))
    let on = one.rect.holds(at.x, at.y)
    if on: over = i
    drawRow(one, on)
    heads[i] = one
    inc i
  # The list itself, headings and all.
  let entries = bindEntries()
  let band = listBox(ControlsListTop, guiH - ControlsListBottom,
    bindRowLeft(guiW), WideWidth, BindRowHeight, entries.len)
  bindScroll = clampScroll(band, bindScroll + notches() * -BindRowHeight)
  drawListFrame(band, bindScroll)
  var chosen = -1
  var resetting = -1
  var e = 0
  while e < entries.len:
    let one = entries[e]
    let slot = rowSlot(band, e, bindScroll)
    inc e
    if slot.bottom <= float(band.top) or slot.y >= float(band.bottom): continue
    if one.kind == HeadingRow:
      setCentred(tr(Categories[one.at]), float(guiW) * 0.5,
        labelBaseline(slot), 1.0, 1.0, 1.0)
      announce(tr(Categories[one.at]), Categories[one.at], slot)
      continue
    let row = one.at
    let why = if bindingWired(row): "" else: BindingReason[row]
    let keyBox = bindKeyRect(guiW, slot)
    let resetBox = bindResetRect(guiW, slot)
    let onKey = keyBox.holds(at.x, at.y) and at.y >= float(band.top) and
      at.y < float(band.bottom)
    let onReset = resetBox.holds(at.x, at.y) and at.y >= float(band.top) and
      at.y < float(band.bottom)
    if onKey: chosen = row
    if onReset: resetting = row
    # The control's own name, right-aligned where the game right-aligns it.
    let named = tr(Bindings[row])
    setRun(named, mrect(bindNameRight(guiW) - float(widthOf(named)),
      labelBaseline(slot), 0.0, 0.0), 1.0, 1.0, 1.0)
    var shown = tr(boundKey(boundTo(binds, row)))
    if capturing == row: shown = waitingLabel(shown)
    elif clashes(binds, row) > 0: shown = clashLabel(shown)
    drawWidget(keyBox, Bindings[row], shown, why.len == 0, onKey)
    announce(named, Bindings[row], slot)
    if why.len > 0:
      announce(ours(why), Bindings[row] & ".why", slot)
      if onKey or onReset:
        setCentred(ours(why), float(guiW) * 0.5,
          float(guiH - ReasonBaseline), 0.66, 0.66, 0.66)
    drawWidget(resetBox, KeyBindReset, tr(KeyBindReset),
      why.len == 0 and boundTo(binds, row) != BindingDefault[row], onReset)
  # Reset Keys and Done, at the game's own two places.
  let resetAll = mrect(float(bindRowLeft(guiW)), float(guiH - ControlsFooter),
    float(ControlsHalfWidth), float(RowHeight))
  let done = mrect(float(bindRowLeft(guiW) + ControlsColumnStep),
    float(guiH - ControlsFooter), float(ControlsHalfWidth), float(RowHeight))
  drawWidget(resetAll, KeyResetAll, tr(KeyResetAll), not atDefaults(binds),
    resetAll.holds(at.x, at.y))
  drawWidget(done, KeyDone, tr(KeyDone), true, done.holds(at.x, at.y))
  # A capture swallows every key, including Escape - which in Minecraft clears
  # the binding rather than leaving the screen.
  if capturing >= 0:
    if pressed(Escape):
      unbind(binds, capturing)
      keepBinds()
      sendBind(capturing)
      capturing = -1
      return
    let got = capturedName()
    if got.len > 0:
      rebind(binds, capturing, got)
      keepBinds()
      sendBind(capturing)
      tell("bound." & Bindings[capturing], got)
      capturing = -1
    return
  if pressed(Escape):
    stack.back()
    return
  if not clicked("left"): return
  if done.holds(at.x, at.y):
    stack.back()
    return
  if resetAll.holds(at.x, at.y) and not atDefaults(binds):
    resetAll(binds)
    keepBinds()
    var b = 0
    while b < Bindings.len:
      if bindingWired(b): sendBind(b)
      inc b
    return
  if resetting >= 0 and bindingWired(resetting):
    resetOne(binds, resetting)
    keepBinds()
    sendBind(resetting)
    return
  if chosen >= 0 and bindingWired(chosen):
    capturing = chosen
    return
  if over >= 0: discard takeRow(heads[over], at, false)

# ---------------------------------------------------------------------------
# Language
#
# Minecraft's `LanguageSelectScreen`: a list of the languages the game has a
# file for, the current one selected, and a warning under it. Picking one is
# real here - the whole menu is drawn out of the table this re-reads, so the
# words change on the next frame and nothing is restarted.
#
# The *list* is the honest gap. `minecraft.gui` answers `lang <code>` for a
# language and has no call that enumerates them, so this asks for `languages`
# and, when nothing answers, offers the one in use and English, and says which
# service call would fill the list. A short list that says it is short beats a
# long one this mod made up.

proc askLanguages() =
  if langListed and ticks mod PollEvery != 0: return
  langListed = true
  languages = linesOf(callService(GuiService, "languages"))
  if languages.len == 0:
    languages = @[]
    if language.len > 0: languages.add language
    if language != FallbackLanguage: languages.add FallbackLanguage
  tell("languages", $languages.len)

proc chooseLanguage(code: string) =
  if code == language or code == langWanted and not askedLang: return
  # The importer builds a language asynchronously. Remember the selection
  # and let askLang keep polling and consume the result in bounded batches.
  langWanted = code
  askedLang = false
  langReading = false
  langBody = ""
  langAt = 0

proc drawLanguageScreen() =
  askLanguages()
  let at = pointerGui()
  drawTitle(titleKey(LanguagePage), LangTitleTop)
  let band = listBox(LangListTop, guiH - LangListBottom,
    guiW div 2 - GridLeft, WideWidth, LangRowHeight, languages.len)
  langScroll = clampScroll(band, langScroll + notches() * -LangRowHeight)
  drawListFrame(band, langScroll)
  var over = -1
  var i = 0
  while i < languages.len:
    let slot = rowSlot(band, i, langScroll)
    inc i
    if slot.bottom <= float(band.top) or slot.y >= float(band.bottom): continue
    let on = slot.holds(at.x, at.y) and at.y >= float(band.top) and
      at.y < float(band.bottom)
    if on: over = i - 1
    drawRowFrame(slot, languages[i - 1] == language)
    setCentred(languages[i - 1], float(guiW) * 0.5, labelBaseline(slot),
      1.0, 1.0, 1.0)
    announce(languages[i - 1], languages[i - 1], slot)
  setCentred(tr(KeyLanguageWarning), float(guiW) * 0.5,
    float(guiH - LangWarning), 0.5, 0.5, 0.5)
  # Announced like every other label. It was not, and nothing noticed while the
  # language table was empty and `tr` was answering every key with the key
  # itself: the script asked for `options.languageWarning`, the screen drew
  # `options.languageWarning`, and the assertion passed for the wrong reason.
  # The moment there were real words behind it, it went red - which is the
  # right way round for a check to fail and the reason this is a one-line fix
  # rather than a puzzle.
  announce(tr(KeyLanguageWarning), KeyLanguageWarning,
    mrect(0.0, float(guiH - LangWarning), float(guiW), float(LineHeight)))
  let unicode = langUnicodeRect(guiW, guiH)
  let done = langDoneRect(guiW, guiH)
  drawWidget(unicode, KeyForceUnicode,
    trf(KeyGenericValue, @[tr(KeyForceUnicode), tr(KeyOff)]), false,
    unicode.holds(at.x, at.y))
  if unicode.holds(at.x, at.y):
    setCentred(ours(UnicodeReason), float(guiW) * 0.5,
      float(guiH - ReasonBaseline), 0.66, 0.66, 0.66)
  announce(ours(UnicodeReason), KeyForceUnicode & ".why", unicode)
  drawWidget(done, KeyDone, tr(KeyDone), true, done.holds(at.x, at.y))
  if pressed(Escape):
    stack.back()
    return
  if not clicked("left"): return
  if done.holds(at.x, at.y):
    stack.back()
    return
  if over >= 0: chooseLanguage(languages[over])

## Which of the nine options screens draws itself. One door, so that a screen
## added to `mcuiopts`'s table is a screen the stack can already reach, and so
## that a page the stack somehow reached with no screen behind it draws nothing
## rather than the wrong thing.
proc drawSettings(page: Page) =
  if page == ControlsPage: drawControlsScreen()
  elif page == LanguagePage: drawLanguageScreen()
  elif isOptionsPage(page): drawOptionsScreen(page)

## Every setting this mod owns, put back the way the player left it. Run once,
## at boot, before anything is drawn - a volume that only took effect the first
## time somebody opened the sound screen would be a setting that is remembered
## and not applied, which is the same as one that is not remembered.
##
## The world's half is not here: it is asked for the first time the world serves
## anything, because a world that has not started cannot be told anything and a
## `no` from one that has not started would be a wrong reason to grey a row with.
proc applyStored() =
  loadOptions()
  let rows = allRows()
  var i = 0
  while i < rows.len:
    let one = rows[i]
    inc i
    if one.reason.len > 0: continue
    if worldName(one.effect).len > 0: continue
    if hereReason(one).len > 0: continue
    if one.key == KeyFullscreen: continue
    applyHere(one, valueOf(one))

# ---------------------------------------------------------------------------
# The pause screen
#
# Escape, and the world dimmed behind it. `mcuipause` is the whole of the
# layout, the whole of the gradient and the whole of the rule about which
# Escape belongs to whom; this is the seam - the keypress, the fills, and the
# one word the world is told.
#
# It does not stop the world, and `mcuipause` gives the four reasons. What it
# takes is the mouse, which is what `mine()` in `aoughwl.voxel` reads: the
# moment the pointer changes hands that world stops steering, digging and
# placing, and goes on falling and generating - which is the half of a pause a
# player asks for and the half they do not.

const Us = "aoughwl.mcui"
  ## This mod's own id, for telling our own rows on the handoff queue from
  ## everybody else's. Not a word anybody reads: `from0` is a mod id.

var
  handoffSeen = 0
  othersHaveIt = false
    ## Whether another mod's screen has the mouse - `aoughwl.hud`'s
    ## inventory, today, which opens over the same world and closes on the same
    ## key. In Minecraft that Escape closes the inventory and does *not* then
    ## open the pause menu, and this is how that is known here.
    ##
    ## Asked of the queue rather than of `pointerLocked()`, for the reason
    ## `aoughwl.voxel` spells out beside its own `captured`: a lock is a
    ## request, a host with no window cannot honour it, and what a mod wants to
    ## know is who asked last rather than what the cursor is doing.
    ##
    ## This mod also *posts* `pointer` rows, and the queue's one rule is that a
    ## mod must not consume a verb it produces - because a row does not say who
    ## it was for. `from0` says who it was from, which is enough: our own rows
    ## are skipped and the rule is kept.

proc readPointer() =
  for one in handed(handoffSeen):
    if one.verb == "pointer" and one.from0 != Us:
      othersHaveIt = one.subject == "free"

proc resumeWorld() =
  handOver("pointer", "held")
  lockPointer()
  say("back to the world")

proc toMainMenu() =
  # The world is left and not hidden, and the stack is thrown away rather than
  # popped: there is nothing behind a world to go back to.
  playing = false
  leaveWorld()
  handOver("world", "menu")
  handOver("pointer", "free")
  stack.resetTo TitlePage
  say("left the world")

proc shareToLan() =
  # `hostGame` is a real host call and this is a real socket, which is why this
  # row is not `menu.online`. What is missing is the rest of Minecraft's own
  # Share to LAN screen - a game mode, cheats, and the port it picked, which
  # the game prints in chat and this has nowhere to print.
  if hostGame(): say("open to lan")
  else: say("could not open to lan: " & networkProblem())

proc takePause(index: int; buttons: seq[MenuButton]) =
  if not buttons[index].enabled: return
  let key = buttons[index].key
  if key == KeyReturnToGame:
    if togglePause(stack) == ClosePause: resumeWorld()
  elif key == KeyOptions:
    stack.go OptionsPage
  elif key == KeyShareToLan:
    shareToLan()
  elif key == KeyReturnToMenu:
    toMainMenu()

## The world, dimmed. Not a sheet of paint over it: Minecraft fills a vertical
## gradient across the scene and goes on drawing the scene, and
## `mcuipause.dimBands` is that gradient in the only shape this surface has for
## one - a stack of flat fills, one per 8-bit step of alpha.
##
## A true blur is **not possible here and is not faked.** Minecraft from 1.20.5
## blurs what is behind an in-world screen, which means reading the frame back
## and running a kernel over it. This surface has `fill`, `drawImage`,
## `writeIn` and a scissor; there is no render target to sample, no shader to
## run, and `drawImage` takes a file rather than the screen, so there is not
## even a cheap fake to reach for. The ramp is exact and the blur is absent,
## which is what the game looked like up to 1.20.4 and is honest about which of
## the two it is.
proc drawDim() =
  let bands = dimBands(screenWidth(), screenHeight())
  var i = 0
  while i < bands.len:
    let one = bands[i]
    inc i
    fill(one.rect.x, one.rect.y, one.rect.w, one.rect.h,
      dimLevel(DimRed), dimLevel(DimGreen), dimLevel(DimBlue), one.alpha)

proc drawPauseScreen() =
  let buttons = pauseButtons(guiW, guiH, shareable(isServer(), isClient()))
  let at = pointerGui()
  let over = buttonUnder(buttons, at.x, at.y)
  drawTitle(pauseTitleKey(), PauseTitleTop)
  var i = 0
  while i < buttons.len:
    drawButton(buttons[i], tr(buttons[i].key), i == over)
    inc i
  if over >= 0 and clicked("left"): takePause(over, buttons)

## The frame, while a world is up.
##
## Escape swings the screen and everything else about the menu carries on
## exactly as it does on the title screen - the importer is polled, the clock
## runs, the caret blinks - because a pause menu that could not open Options
## would be a pause menu with one button on it.
proc pauseUpdate() =
  readPointer()
  if pressed(Escape) and not othersHaveIt:
    let move = togglePause(stack)
    if move == OpenPause:
      handOver("pointer", "free")
      say("paused")
    elif move == ClosePause:
      resumeWorld()
  if not menuUp(stack): return
  poll()
  grantUpdate()
  clock = clock + deltaTime()
  inc caretTicks
  freePointer()

# ---------------------------------------------------------------------------
# The frame

proc start() =
  publishPicture(StudioLogo, "aoughwlstudios.png")
  hasStudio = true
  publishPicture(EditionLogo, "aoughwledition.png")
  hasEdition = true
  loadOptions()
  loadBinds()
  applyStored()
  tell("skin", "none")
  say("waiting for " & Provider & " to publish an interface")

proc update() =
  # The frame that just went by, which is the only measurement of this mod's own
  # cost that exists. See `paceRows`.
  paceRows(int(deltaTime() * 1000.0))
  # Request metrics at the very start of the first frame; the loading screen is
  # still drawn immediately while the request completes.
  if not askedFont: askFont()
  # The first frame the world offers to be told anything, it is told everything.
  # Here and not in `start()`, because a service is registered in the providing
  # mod's own `start()` and load order is not a thing any mod here is allowed to
  # depend on.
  if not worldAsked and serves(WorldSettings): pushWorld()
  if playing:
    # The menu is not over: Escape brings it back. See `pauseUpdate`.
    pauseUpdate()
    return
  poll()
  clock = clock + deltaTime()
  inc caretTicks
  if not handedOver:
    # Said once, on the first frame rather than in start(), so that every mod's
    # start() has run and the world is listening before it is told the menu has
    # the mouse. `aoughwl.voxel` reads this and stops digging and looking;
    # nothing else in the pack produces this verb while a screen is up.
    handedOver = true
    # And which of the two things is in front of the player, which is a
    # different question from who has the mouse and is answered separately
    # because the pause screen is both at once: a menu WITH the mouse, over a
    # world that is still there. `aoughwl.hud` reads this one - the hearts
    # and the hunger belong behind the pause screen, exactly as they do in the
    # game, and nowhere near the title screen, which is the bug it fixes.
    handOver("world", "menu")
    handOver("pointer", "free")
  freePointer()

proc drawGui() =
  let w = int(screenWidth())
  let h = int(screenHeight())
  if w <= 0 or h <= 0: return
  scaleNow = guiScale(w, h, scaleSetting)
  guiW = guiWidth(w, scaleNow)
  guiH = guiHeight(h, scaleNow)
  tell("scale", $scaleNow)
  let loading = settling(stack, heardImporter)
  if loading:
    if not loadingCap:
      frameRate(30)
      loadingCap = true
  elif loadingCap:
    frameRate(frameCap)
    loadingCap = false
  if loading: tell("screen", "loading")
  else: tell("screen", screenWord(here(stack)))
  # The loading screen paints its own ground and is not a screen over the menu:
  # it is what is on the screen instead of one.
  if loading or here(stack) == LoadingPage:
    drawLoading()
    return
  # While a world is up, the menu is the pause screen and whatever the pause
  # screen opened over itself - and the backdrop is the world, dimmed and still
  # being drawn, rather than the dirt. A world with no screen over it draws
  # nothing at all from here, which is what it did before this existed.
  if playing:
    if here(stack) == WorldPage: return
    drawDim()
    if here(stack) == PausePage: drawPauseScreen()
    elif here(stack) == PacksPage: drawPacks()
    else: drawSettings(here(stack))
    return
  let where = here(stack)
  if notice.state == NoGrant:
    drawGrantScreen()
    return
  drawBackdrop(where == TitlePage)
  if where == TitlePage: drawTitleScreen()
  elif where == WorldsPage: drawWorlds()
  elif where == CreatePage: drawCreate()
  elif where == ServersPage: drawServers()
  elif where == AddServerPage: drawAddServer()
  elif where == PacksPage: drawPacks()
  else: drawSettings(where)

proc stop() = discard
