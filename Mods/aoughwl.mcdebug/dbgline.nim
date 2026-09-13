## What a line on the debug screen IS, before anything draws one.
##
## Minecraft's F3 screen is a list in `DebugScreenOverlay.java`. Every line on
## it is a `String.format` written into that file, which is why adding one
## means editing the game. This mod holds the same screen as **rows in a
## catalog**, so the list is open: a mod that knows something publishes a row
## saying what it knows and where it goes, and this mod - which knows none of
## them - draws it.
##
## ## Why the value is a SERVICE and not the row
##
## A catalog is a noticeboard. It is append-only and read when the reader gets
## round to it, which is exactly right for "here is what I contribute" and
## useless for "what is this worth right now" (`ModSdk/services.nim` says this
## in its own first paragraph, and it is the reason that module exists). A
## debug screen is entirely made of "right now".
##
## So the row carries the *declaration* and the service carries the *value*:
##
##     id        voxel.chunk           what this line is
##     section   left                  which column
##     order     120                   where in that column
##     key       debug.chunk           the translation key of its label
##     service   voxel.debug           who to ask
##     arg       chunk                 what to ask them
##     every     4                     frames between asking
##
## Nothing in that row is understood by this mod except where to put it and who
## to ask. `voxel.debug` is a name this mod has never heard of; `chunk` is a
## word this mod does not parse. `aoughwl.voxel` publishes the row and
## answers the service, `aoughwl.hud` publishes its own, and a third-party
## mod publishes a third, and the debug screen's source does not change for any
## of them. That is the whole test of the design and it is the reason the value
## is not in the row.
##
## ## Sections, order and on/off are data too
##
## Every field above can be moved by a config a modpack or a player ships,
## parsed by `parseConfig` below and applied over the catalog by `applyTo`. A
## row in that config names a line and only the fields it wants to move:
##
##     voxel.chunk     order=205
##     mcdebug.memory  on=0
##     *               every=20
##
## `*` is every line at once, which is how "turn the whole screen down to five
## times a second" is said in one row.
##
## ## What is not here
##
## No host call, no drawing, no formatting of anybody's number. This module is
## a grammar and an ordering and `Tests/mcdebug_test.exe` proves both in a
## millisecond.

type
  Section* = enum
    ## Minecraft's two columns. The left one is the world, the right one is the
    ## machine. Nothing else is a section, because nothing else is one in the
    ## game either.
    LeftSection, RightSection

  DebugLine* = object
    id*: string
      ## The catalog item id, which is also the default argument. Namespaced by
      ## whoever published it - `voxel.chunk`, not `chunk` - so two mods that
      ## both have something to say about chunks do not collide.
    provider*: string
      ## The mod that contributed the row. The catalog already knows this, so
      ## nothing has to be told it.
    section*: Section
    order*: int
    key*: string
      ## A translation key for the label, looked up in the player's own
      ## language file. A key with nothing behind it draws as the key, which is
      ## what the game does everywhere else and what `mcuilang` already does.
    label*: string
      ## A literal label out of the config, for a line the game has no key for.
      ## `key` wins when both are set. This exists so a player can write the
      ## words they want without shipping them in anybody's source.
    service*: string
      ## Who to ask for the value. Empty means nothing can source this line -
      ## see `needs`.
    argument*: string
      ## What to ask them. Defaults to the id, so a row that says nothing about
      ## its argument still asks a question that names itself.
    every*: int
      ## Frames between refreshes. One is every frame. This is the only cost
      ## lever on the screen and it is data, so a line that is expensive to
      ## answer can be turned down without touching a mod.
    on*: bool
    needs*: string
      ## For a line that is declared and CANNOT be sourced: the name of the
      ## host capability it wants. A gap on the screen with a name beside it in
      ## the log is worth more than a line that quietly is not there, and worth
      ## far more than a number somebody invented to fill it.
    value*: string
      ## The last answer. Not part of the grammar; carried here so the poll and
      ## the layout speak in one shape.
    answered*: bool
      ## Whether it has ever been answered at all. An empty answer from a
      ## provider that spoke is not the same as no provider, and the screen
      ## must be able to tell them apart - which is exactly the distinction
      ## `serviceProblem()` exists for on the other side of the call.

const
  DefaultEvery*: int = 1
  EveryLine*: string = "*"
    ## The config id that means every line.

proc newLine*(id, provider: string): DebugLine =
  DebugLine(id: id, provider: provider, section: LeftSection, order: 0,
    key: "", label: "", service: "", argument: "", every: DefaultEvery,
    on: true, needs: "", value: "", answered: false)

# ---------------------------------------------------------------------------
# Reading other people's text
#
# Every value below arrives from a catalog row or a config file, both of which
# are somebody else's data. A malformed one must cost a strange-looking line
# and never the frame, so each of these takes a fallback and returns it rather
# than failing.

proc wholeOf*(text: string; fallback: int): int =
  var value = 0
  var sign = 1
  var digits = false
  var i = 0
  while i < text.len:
    let c = text[i]
    if c == '-' and not digits and i == 0: sign = -1
    elif c >= '0' and c <= '9':
      value = value * 10 + (int(c) - int('0'))
      digits = true
    else: return fallback
    inc i
  if not digits: return fallback
  value * sign

proc truth*(text: string; fallback: bool): bool =
  if text == "1" or text == "true" or text == "on" or text == "yes": return true
  if text == "0" or text == "false" or text == "off" or text == "no": return false
  fallback

# ---------------------------------------------------------------------------
# The grammar
#
# `name=value`, space separated, and a value with spaces in it is quoted. That
# is the whole of it. It is a grammar and not JSON because it has to be
# writable in a catalog row - one string - as comfortably as in a file, and
# because a modpack author editing a line ought to be able to change one field
# without balancing a brace.

## One field, moved. An unknown name is ignored ON PURPOSE: a row written by a
## mod newer than this one still lands, with the fields this version
## understands, rather than being thrown out whole for one word it has not
## heard of.
proc assign*(line: var DebugLine; name, value: string) =
  if name == "section":
    if value == "right": line.section = RightSection
    elif value == "left": line.section = LeftSection
  elif name == "order": line.order = wholeOf(value, line.order)
  elif name == "key": line.key = value
  elif name == "label": line.label = value
  elif name == "service": line.service = value
  elif name == "arg": line.argument = value
  elif name == "every":
    let n = wholeOf(value, line.every)
    line.every = if n < 1: 1 else: n
  elif name == "on": line.on = truth(value, line.on)
  elif name == "needs": line.needs = value

## A whole row of fields, over whatever the line already says. This is both the
## catalog row's parser and the config override's parser, which is the point:
## an override is not a second grammar, it is the same one applied to a line
## that already exists.
proc readRow*(line: var DebugLine; row: string) =
  var i = 0
  while i < row.len:
    while i < row.len and (row[i] == ' ' or row[i] == '\t'): inc i
    if i >= row.len: return
    var name = ""
    while i < row.len and row[i] != '=' and row[i] != ' ' and row[i] != '\t':
      name.add row[i]
      inc i
    if i >= row.len or row[i] != '=':
      # A word with no `=` in it. Skipped rather than guessed at.
      while i < row.len and row[i] != ' ' and row[i] != '\t': inc i
    else:
      inc i
      var value = ""
      if i < row.len and row[i] == '"':
        inc i
        while i < row.len and row[i] != '"':
          value.add row[i]
          inc i
        if i < row.len: inc i
      else:
        while i < row.len and row[i] != ' ' and row[i] != '\t':
          value.add row[i]
          inc i
      assign(line, name, value)

## One named field out of a row, for a row that is not a line - the reserved
## `screen` row is the only one, and it wants three settings that are not a
## line's settings. Same grammar, so there is one grammar.
proc fieldOf*(row, want, fallback: string): string =
  result = fallback
  var found = false
  var i = 0
  while i < row.len:
    while i < row.len and (row[i] == ' ' or row[i] == '\t'): inc i
    if i >= row.len: return result
    var name = ""
    while i < row.len and row[i] != '=' and row[i] != ' ' and row[i] != '\t':
      name.add row[i]
      inc i
    if i >= row.len or row[i] != '=':
      while i < row.len and row[i] != ' ' and row[i] != '\t': inc i
    else:
      inc i
      var value = ""
      if i < row.len and row[i] == '"':
        inc i
        while i < row.len and row[i] != '"':
          value.add row[i]
          inc i
        if i < row.len: inc i
      else:
        while i < row.len and row[i] != ' ' and row[i] != '\t':
          value.add row[i]
          inc i
      # The LAST one of a name wins, matching `readRow`, where a later
      # assignment overwrites an earlier one.
      if name == want:
        result = value
        found = true
  if not found: return fallback
  result

## A catalog row, as a line. The argument falls back to the id so that a row
## which says nothing about what to ask still asks a question that names
## itself - which is what a one-line-per-mod provider wants.
proc lineFrom*(id, provider, row: string): DebugLine =
  result = newLine(id, provider)
  readRow(result, row)
  if result.argument.len == 0: result.argument = id

# ---------------------------------------------------------------------------
# The config a player or a modpack ships

type
  Config* = object
    id*: seq[string]
    row*: seq[string]

proc noConfig*(): Config = Config(id: @[], row: @[])

proc rows*(c: Config): int = c.id.len

## `# ...` is a comment, a blank line is nothing, and everything else is
## `<id> <field>=<value> ...`. Two rows naming one line are both kept and
## applied in order, so a modpack layered over the mod's own defaults overrides
## field by field rather than wholesale - the rule a resource pack's language
## file follows, spelled again here because it is the rule that makes layering
## worth having.
proc parseConfig*(body: string): Config =
  result = noConfig()
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
        # The gap between the id and the first field is not part of either.
        while j < line.len and (line[j] == ' ' or line[j] == '\t'): inc j
        var rest = ""
        while j < line.len:
          if line[j] != '\r': rest.add line[j]
          inc j
        if id.len > 0:
          result.id.add id
          result.row.add rest
      line = ""
    else:
      line.add body[i]
    inc i

## The config, over the catalog. Every line the config names moves; `*` names
## them all. A row for a line nobody published does nothing, silently, because
## a config that mentions a mod the player has not installed is normal and not
## an error.
proc applyTo*(c: Config; lines: var seq[DebugLine]) =
  var r = 0
  while r < c.id.len:
    var i = 0
    while i < lines.len:
      if c.id[r] == EveryLine or lines[i].id == c.id[r]:
        var one = lines[i]
        readRow(one, c.row[r])
        lines[i] = one
      inc i
    inc r

# ---------------------------------------------------------------------------
# Order
#
# The screen must not shuffle. Two mods that both picked 100 have to come out
# in the same order this run and next run, and load order is not that: a
# modpack that loads its mods in a different order would otherwise redraw the
# screen differently for no reason a player could see.

## Whether `a` sorts after `b`: the order first, and the id second so that a
## tie is broken by something that does not depend on who loaded first.
proc laterId*(a, b: string): bool =
  var i = 0
  while i < a.len and i < b.len:
    if a[i] != b[i]: return int(a[i]) > int(b[i])
    inc i
  a.len > b.len

proc after*(a, b: DebugLine): bool =
  if a.order != b.order: return a.order > b.order
  laterId(a.id, b.id)

## Which lines are in that column, in the order they are drawn. Indices into
## `lines`, so nothing is copied and the poll and the layout are talking about
## the same rows. Insertion sort: this is a few dozen rows and it is run when
## the catalog changes, not per frame.
proc ordered*(lines: seq[DebugLine]; section: Section): seq[int] =
  result = @[]
  var i = 0
  while i < lines.len:
    if lines[i].on and lines[i].section == section:
      result.add i
      var at = result.len - 1
      while at > 0 and after(lines[result[at - 1]], lines[result[at]]):
        # Both read before either is written: an assignment from one element of
        # a seq into another is an alias, and this toolchain refuses one.
        let lower = result[at - 1]
        let higher = result[at]
        result[at - 1] = higher
        result[at] = lower
        at = at - 1
    inc i

## Whether a line has a source at all. A line without one is still drawn, in
## its place, saying so - a screen with a named gap in it is honest and a
## screen with the gap silently closed up is not.
proc sourced*(line: DebugLine): bool = line.service.len > 0
