## What the debug screen costs, and the two rules that stop it costing that.
##
## This screen is drawn every frame, and every value on it comes from another
## mod through `callService`. The measured cost model for this boundary is a
## host crossing at 0.68us plus 0.30us an argument, and an interpreted proc
## call at 2.1us - so one `callService` is the crossing (two string arguments,
## 1.28us), the interpreter being re-entered at the provider (2.1us), and
## whatever the provider then does. Call it ten microseconds, honestly rounded
## up.
##
## Forty lines asking one question each, every frame, is 400us. That is 2.4% of
## a 60Hz frame spent on a screen whose entire purpose is to tell you where
## your frames went, which is the joke that writes itself. Two rules, both
## arithmetic and both proved next door, take it to about a tenth of that.
##
## ## One: a line says how often it needs asking
##
## `every` is frames between refreshes, and it is a field on the row, so a mod
## that knows its answer changes once a second says so. XYZ is `every=1`
## because it moves every frame. The frame rate, the chunk count and the memory
## line are not: they are `every=20` and nobody can tell.
##
## ## Two: the ones that are due are SPREAD, not synchronised
##
## Twenty lines at `every=20` all refreshing on frame 0 is not cheaper than
## twenty lines at `every=1`; it is the same work with a stutter in it. So each
## line's phase is its own index, and twenty lines at `every=20` refresh one a
## frame for ever. `phaseOf` is the whole of that idea and `spread` below is
## the assertion it exists for.
##
## ## And one that is not arithmetic: ask each provider once
##
## Four lines from `aoughwl.voxel` due on the same frame are four
## crossings and four interpreter re-entries to ask one mod four questions.
## `asksFor` groups them by service, so it is one crossing and one re-entry
## carrying four arguments, and the answer comes back as a table. That shape is
## not invented here: `minecraft.gui` already answers `lang` with a whole
## `key<TAB>value` table in one call, for the same reason.
##
## `crossings` and `unbatched` below are the two numbers, so the saving is a
## measurement in a test rather than a claim in this comment.

import dbgline

## Which frame in its cycle a line refreshes on. Its own index, so a screen of
## lines that all chose the same period still spreads them one to a frame
## instead of landing them all together.
proc phaseOf*(index, every: int): int =
  if every <= 1: return 0
  var p = index mod every
  if p < 0: p = p + every
  p

## Whether that line is due this frame.
proc due*(frame, index, every: int): bool =
  if every <= 1: return true
  var m = (frame - phaseOf(index, every)) mod every
  if m < 0: m = m + every
  m == 0

# ---------------------------------------------------------------------------
# One question per provider, not one per line

type
  Ask* = object
    service*: string
    argument*: string
      ## Every due row of that service's argument, newline separated. One
      ## string, because the boundary carries one string.
    rows*: seq[int]
      ## Which lines they were, in the order they were asked.

proc noAsk*(service, argument: string; row: int): Ask =
  Ask(service: service, argument: argument, rows: @[row])

## Every question this frame has to ask, one per service rather than one per
## line. The order services come out in is the order their first due line
## appears, which is the catalog's own order and therefore stable.
proc asksFor*(lines: seq[DebugLine]; frame: int): seq[Ask] =
  result = @[]
  var i = 0
  while i < lines.len:
    if lines[i].on and sourced(lines[i]) and due(frame, i, lines[i].every):
      var at = -1
      var s = 0
      while s < result.len:
        if result[s].service == lines[i].service and at < 0: at = s
        inc s
      if at < 0:
        result.add noAsk(lines[i].service, lines[i].argument, i)
      else:
        var one = result[at]
        one.argument = one.argument & "\n" & lines[i].argument
        one.rows.add i
        result[at] = one
    inc i

## How many times the boundary is crossed this frame to fill the screen.
proc crossings*(asks: seq[Ask]): int = asks.len

## What it would have cost with a call a line - the number this module exists
## to be smaller than.
proc unbatched*(asks: seq[Ask]): int =
  result = 0
  var i = 0
  while i < asks.len:
    result = result + asks[i].rows.len
    inc i

## How many arguments the crossing carries, which is the part of the cost model
## that is per-argument. One string however many rows are in it, so this is the
## count of asks and not the count of rows - said here so a test can assert the
## difference rather than a comment claiming it.
proc arguments*(asks: seq[Ask]): int = asks.len * 2

# ---------------------------------------------------------------------------
# The answer, spread back over the rows that asked

proc firstTab(text: string): int =
  result = -1
  var i = 0
  while i < text.len:
    if text[i] == '\t' and result < 0: result = i
    inc i

## The provider's reply, back onto the lines. One `<argument><TAB><value>` a
## line - the shape `minecraft.gui` already answers `lang` in.
##
## Matched by argument and not by position, deliberately. A provider that was
## asked four things and answers three is normal: one of them may have had
## nothing to say this frame. Positionally that would put the third answer
## under the fourth label, which is the single worst thing a debug screen can
## do, because every number on it would still look like a number. By argument
## the fourth simply keeps what it last said.
##
## A value the provider does not send is not cleared. A line that has never
## been answered stays `answered = false`, which is what the screen shows as a
## gap rather than as an empty value - an important difference, because a
## provider is allowed to answer "" on purpose.
proc applyAnswer*(lines: var seq[DebugLine]; ask: Ask; answer: string) =
  var row = ""
  var i = 0
  while i <= answer.len:
    if i == answer.len or answer[i] == '\n':
      let tab = firstTab(row)
      if tab > 0:
        var name = ""
        var j = 0
        while j < tab:
          name.add row[j]
          inc j
        var value = ""
        j = tab + 1
        while j < row.len:
          if row[j] != '\r': value.add row[j]
          inc j
        var r = 0
        while r < ask.rows.len:
          let at = ask.rows[r]
          if lines[at].argument == name:
            var one = lines[at]
            one.value = value
            one.answered = true
            lines[at] = one
          inc r
      row = ""
    else:
      row.add answer[i]
    inc i

## Every line that has been answered at least once. The number the play script
## and the log line are about: a screen where this is zero is a screen that is
## drawing labels over nothing.
proc answeredCount*(lines: seq[DebugLine]): int =
  result = 0
  var i = 0
  while i < lines.len:
    if lines[i].answered: inc result
    inc i

## The worst number of lines any single frame of a whole cycle has to refresh.
## With phases spread this is about the count divided by the period; without
## them it is the count. It is the assertion `phaseOf` exists for.
proc busiestFrame*(lines: seq[DebugLine]; over: int): int =
  result = 0
  var frame = 0
  while frame < over:
    var n = 0
    var i = 0
    while i < lines.len:
      if lines[i].on and sourced(lines[i]) and due(frame, i, lines[i].every):
        inc n
      inc i
    if n > result: result = n
    inc frame
