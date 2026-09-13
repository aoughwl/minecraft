## The lines about the machine, published for whatever debug screen is loaded.
##
## Minecraft's F3 screen has a handful of lines that are about no part of the
## game: where the eye is, how big the window is, how fast frames are going by,
## which build this is. In the real game they are in the same file as the rest.
## Here they are their own mod, and it is worth saying why there are two mods
## rather than one.
##
## **A mod cannot call its own service.** `ModSdk/services.nim` says so and
## refuses it at the call: "aoughwl.mcdebug serves 'mcdebug.host' itself;
## call the proc directly instead." So a debug screen that also published lines
## would have had to reach its own values by a path no other mod could use -
## and the mechanism every other line depends on would then be untested for the
## case that matters, which is a mod nobody has written yet.
##
## Split, `aoughwl.mcdebug` has NO lines of its own. Every line on that
## screen, including these, arrives the way a stranger's does: a row in
## `aoughwl.debug.lines` saying where it goes and who to ask, and a
## service answering when asked. The screen names neither this mod nor any
## other, and `Tests/mcdebug_test.exe` reads its source back and fails if it
## ever does.
##
## ## What is here and what is not
##
## The rows are in `debug.conf` beside this file, not in this file. What is
## here is the answering: seven arguments, each one host call or two, and the
## arithmetic that turns them into the strings Minecraft writes. That
## arithmetic is in `aoughwl_mcdebug/dbgfmt`, which is pure and proved
## next door - a coordinate line rounded the way `%.3f` rounds is exactly the
## sort of thing that is wrong by one in the last place for a year.
##
## ## The lines that are declared here and cannot be answered
##
## `debug.conf` also declares Minecraft's memory, allocation, CPU and GPU
## lines, each with the host call it wants written beside it, and answers none
## of them. There is no host call for any of them, and no way round it: every
## door to one is a Unity **static** (`GC.GetTotalMemory`,
## `Profiler.GetTotalAllocatedMemory`, every field of `SystemInfo`) and the
## reflection escape hatch in this surface invokes public **instance** members
## only. So the line is drawn, in its place, saying it has no value, and the
## call it wants is in the log at start-up. A screen with a named gap in it is
## honest; a screen with a plausible number in the gap is the worst thing a
## debug screen can be.

import jester
import services
import importing
import render
import aoughwl_mcdebug/dbgfmt

const
  LineKind = "aoughwl.debugline"
  LineCatalog = "aoughwl.debug.lines"
  Service = "hostdebug.lines"
  ConfFile = "debug.conf"

var
  fpsFrames = 0
  fpsAt = 0.0
  fpsNow = 0
  published = 0

proc say(text: string) = log("[hostdebug] " & text)

proc tell(name, value: string) = log("[assert] hostdebug." & name & "=" & value)

# ---------------------------------------------------------------------------
# Publishing
#
# The kind is declared and the catalog created only if nobody has yet, which is
# the rule `provideScheme` follows: whichever of the debug mods loads first
# owns the catalog and the other simply adds to it. That is what lets this mod
# and the screen load in either order, and what lets a third mod turn up later.

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

## Every line in this mod's data file, into the shared catalog. Not one of them
## is read by anything here: the row says where it goes and who to ask, and
## both of those are the screen's business and the service's, never this
## procedure's.
proc publishLines() =
  # The kind and the catalog under ONE guard, never separately. A kind belongs
  # to the mod that declared it and a second mod declaring the same id is
  # refused outright - three mods in this pack publish debug lines and any of
  # them may load first, so every one of them must be willing to make the
  # catalog and none of them may ever declare the kind without making it.
  if catalogSignature(LineCatalog).len == 0:
    defineCatalogKind(LineKind, "text",
      "One line on a debug screen: where it goes and who to ask for it.")
    createCatalog(LineCatalog, LineKind,
      "What every mod has to say about itself, a line at a time.")
  let body = readOwn(ConfFile)
  if body.len == 0:
    say("no " & ConfFile & "; nothing to publish")
    return
  var line = ""
  var i = 0
  while i <= body.len:
    if i == body.len or body[i] == '\n':
      var j = 0
      while j < line.len and (line[j] == ' ' or line[j] == '\t'): inc j
      if j < line.len and line[j] != '#':
        var id = ""
        while j < line.len and line[j] != ' ' and line[j] != '\t':
          if line[j] != '\r': id.add line[j]
          inc j
        while j < line.len and (line[j] == ' ' or line[j] == '\t'): inc j
        var rest = ""
        while j < line.len:
          if line[j] != '\r': rest.add line[j]
          inc j
        if id.len > 0:
          addToCatalog(LineCatalog, id, rest)
          inc published
      line = ""
    else:
      line.add body[i]
    inc i
  tell("lines", $published)

# ---------------------------------------------------------------------------
# Answering
#
# Frames a second is COUNTED here rather than asked for, because there is no
# host call that reports one. `framesDrawn()` is the host's count of frames it
# really drew - not the number of times `update()` ran, which is the number a
# mod would get wrong by using - and `gameTime()` is the span to divide it by.
# Re-based every half second so it settles quickly and still does not flicker.

proc countFrames() =
  let now = gameTime()
  if fpsAt == 0.0:
    fpsAt = now
    fpsFrames = framesDrawn()
    return
  let span = now - fpsAt
  if span < 0.5: return
  fpsNow = rate(framesDrawn() - fpsFrames, span)
  fpsAt = now
  fpsFrames = framesDrawn()

## `eyeAvailable()` is asked before every reading of the eye, and it is not
## caution: headless, or before a camera exists, the three axes read 0, 0, 0 -
## which is a place a player can really be standing. A screen that showed it
## would be lying at exactly the moment somebody was trying to find out what
## was wrong.
proc answerOne(what: string): string =
  if what == "xyz":
    if not eyeAvailable(): return ""
    return coords(eyeX(), eyeY(), eyeZ())
  if what == "eyeblock":
    if not eyeAvailable(): return ""
    return blocks(eyeX(), eyeY(), eyeZ())
  if what == "axis":
    if not eyeAvailable(): return ""
    return axisOf(eyeForwardX(), eyeForwardZ())
  if what == "fps": return $fpsNow
  if what == "display": return size(int(screenWidth()), int(screenHeight()))
  if what == "host": return hostVersion()
  if what == "sdk": return hostSdk()
  ""

## The screen asks its whole list in one call and takes a table back - one
## `<argument><TAB><value>` a line. That shape is not invented for this: it is
## how `minecraft.gui` already answers `lang`, and it is what makes six lines
## from one mod one crossing instead of six.
##
## An argument this mod does not know is answered with an empty line rather
## than skipped, so the caller can tell "I do not know that" from "I did not
## hear you".
proc serveRequest() =
  if serviceName() != Service: return
  var reply = ""
  var one = ""
  let asked = serviceArgument()
  var i = 0
  while i <= asked.len:
    if i == asked.len or asked[i] == '\n':
      if one.len > 0: reply = reply & one & "\t" & answerOne(one) & "\n"
      one = ""
    else:
      one.add asked[i]
    inc i
  answerService(reply)

proc start() =
  publishLines()
  provideService(Service)
  say($published & " lines published; " & Service & " answers them")

proc update() =
  countFrames()

proc stop() = discard
