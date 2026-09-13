## What the interface needs out of the player's own copy, measured here because
## this is the mod that can see it.
##
## `aoughwl.mcui` draws a Minecraft title screen. It cannot read the jar,
## it cannot walk the resource-pack layer stack and it has no PNG decoder, and
## it should not grow any of the three - those are this mod's, and duplicating
## them is how two readers of the same format start disagreeing about a pack.
## So this file is the seam: three measurements that need the files, handed over
## the service boundary as text.
##
## **The font.** Not the advances - the *columns*. Minecraft's advance rule is
## "the rightmost column of the cell that has anything in it, rounded to the
## nominal cell size, plus one for the gap, except a space which is four", and
## that rule belongs where the layout is, in `mcui/mcuifont.nim`, with the test.
## What belongs here is the half that needs the pixels: for each of the 256
## cells, which column was the rightmost with an opaque pixel in it.
## `Tests/mcui_test.exe` compiles both halves and asserts they agree on a sheet
## it builds itself, so the split cannot rot.
##
## **The language file.** A flat `key<TAB>value` a line, out of the JSON this
## mod already parses, resolved through the layer stack this mod already walks -
## so a pack that overrides three strings overrides three strings and the jar
## answers for the rest. The escape is two characters and is spelled the same
## way on both sides.
##
## **The splashes.** Nothing to do: the file is lines already.
##
## Nothing in here calls a host.

import mcpng
import mcjson

const
  FontCells* = 16
    ## 16 by 16 cells, whatever the sheet measures.
  FontGlyphs* = FontCells * FontCells

## For each of the 256 cells of a font sheet, the rightmost column in it that
## has any opaque pixel, or -1 when the cell is empty.
##
## This is deliberately the same fifteen lines as `mcuifont.rightmostColumns`,
## and the test asserts the two agree rather than trusting that they do. They
## are two copies because they are in two mods and a mod cannot import another
## mod's private module; the thing that keeps them honest is the assertion, not
## the discipline.
proc fontColumns*(img: Image): seq[int] =
  result = @[]
  if img.width <= 0 or img.height <= 0: return result
  let cellW = img.width div FontCells
  let cellH = img.height div FontCells
  if cellW <= 0 or cellH <= 0: return result
  var i = 0
  while i < FontGlyphs:
    let col = i mod FontCells
    let row = i div FontCells
    var rightmost = -1
    var l = cellW - 1
    while l >= 0:
      var opaque = false
      var y = 0
      while y < cellH:
        let at = ((row * cellH + y) * img.width + col * cellW + l) * 4 + 3
        if at < img.rgba.len and img.rgba[at] != 0:
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

## The line the font service answers with: the cell size, then the 256 columns.
proc fontLine*(img: Image): string =
  let cols = fontColumns(img)
  if cols.len == 0: return ""
  result = $(img.width div FontCells) & " " & $(img.height div FontCells)
  var i = 0
  while i < cols.len:
    result.add " "
    result.add $cols[i]
    inc i

# ---------------------------------------------------------------------------
# How a sprite is allowed to be resized
#
# Minecraft 1.20.2 took `gui/widgets.png` away. There is no sheet any more: a
# button is `gui/sprites/widget/button.png`, its hovered state is
# `button_highlighted.png`, and each one is its own file with a `.mcmeta` beside
# it saying how it may be stretched.
#
#     {"gui": {"scaling": {"type": "nine_slice",
#                          "width": 200, "height": 20, "border": 3}}}
#
# That is strictly better than what it replaced, because the slicing is now
# **data**. The 1.21.11 jar says `"border": 3`; Faithful 64x says
# `{"left": 20, "top": 4, "right": 20, "bottom": 4}` for the same button; a pack
# tomorrow may say something else again. Anything that hard-codes a border is
# wrong for one of those three and cannot be told which.
#
# Three types exist and all three are read:
#
#   `stretch`     the whole sprite over the whole rectangle
#   `nine_slice`  corners at their own size; `border` is a number for all four
#                 or an object naming each
#   `tile`        repeated, at its own `width` by `height`
#
# The numbers are **nominal**: `width` and `height` are what the sprite counts
# as, not what the file measures. Faithful's button.png is 800 by 80 and says
# 200 by 20, and everything downstream works in the nominal size and divides by
# it, which is why a 4x pack needs no special case anywhere.
#
# The line this hands over is the whole of it. `mcui/mcuisprite.nim` parses it
# and turns it into quads, and `Tests/mcui_test.exe` runs the real jar's mcmeta
# and the real pack's mcmeta through both halves.

## One `.mcmeta`'s `gui.scaling`, as a line. "" when the file has no `gui` block
## at all - which is normal: a `.mcmeta` beside a texture is just as often an
## animation schedule, and `music_notes.png.mcmeta` in the jar is `{}`.
proc scalingLine*(doc: Json): string =
  if doc.root < 0: return ""
  let gui = member(doc, doc.root, "gui")
  if gui < 0: return ""
  let scaling = member(doc, gui, "scaling")
  if scaling < 0: return ""
  let kind = text(doc, member(doc, scaling, "type"))
  let width = int(number(doc, member(doc, scaling, "width"), 0.0))
  let height = int(number(doc, member(doc, scaling, "height"), 0.0))
  if kind == "tile":
    return "tile " & $width & " " & $height
  if kind != "nine_slice":
    # `stretch`, or a type invented after this was written. Stretching is what
    # the game does for anything it has no slicing for, so it is also the right
    # answer for a type nobody here has heard of.
    return "stretch"
  let border = member(doc, scaling, "border")
  var left = 0
  var top = 0
  var right = 0
  var bottom = 0
  if kindAt(doc, border) == jNumber:
    left = int(number(doc, border, 0.0))
    top = left
    right = left
    bottom = left
  elif kindAt(doc, border) == jObject:
    left = int(number(doc, member(doc, border, "left"), 0.0))
    top = int(number(doc, member(doc, border, "top"), 0.0))
    right = int(number(doc, member(doc, border, "right"), 0.0))
    bottom = int(number(doc, member(doc, border, "bottom"), 0.0))
  "nine " & $width & " " & $height & " " & $left & " " & $top & " " &
    $right & " " & $bottom

# ---------------------------------------------------------------------------
# Which version, and whether the player's packs fit it
#
# `versions/` is not a list of installed Minecrafts. It is a list of versions the
# launcher has *heard of*: a folder with only a `.json` in it is one that was
# never downloaded. On the machine this was written against there are eight
# folders and two jars.
#
# The old rule here was "the biggest jar", which happens to work and is a proxy
# for nothing. It would pick a modded jar with a shader bundle in it over the
# vanilla one beside it, and it says nothing a player could check. So the rule
# is the version number, over folders that actually contain a jar, with a plain
# release beating a release candidate beating a pre-release beating a snapshot
# of the same number.
#
# The launcher's own opinion was tried first and does not survive contact:
# `launcher_profiles.json` on this machine says `"lastVersionId":
# "latest-release"`, a symbolic name the launcher resolves against a manifest it
# downloads. Following it would mean this game making a network request to find
# out which Minecraft is on the disk in front of it. So it is not followed, and
# `chooseJar` is deterministic and reads nothing.
#
# **The format is the other half.** A jar declares which resource-pack format it
# speaks in its own `version.json`, and a pack declares the range it was made
# for in `pack.mcmeta`. When they do not overlap Minecraft itself says "made for
# an older version" and applies it anyway; the layering here does the same thing
# and would quietly leave every renamed path falling through to the jar. So the
# numbers are read and compared, and the answer is said out loud rather than
# half-drawn. On this machine that comparison is worth having: Faithful 64x
# declares 79 to 100, `26.2` speaks 88 and fits, and `1.21.11` speaks 75 and
# does not - which is the opposite of what anybody guessed.

type Version* = object
  name*: string
  parts*: seq[int]
  stage*: int   ## 3 a release, 2 a release candidate, 1 a pre-release, 0 a snapshot
  order*: int   ## the number after that word, so `rc-2` beats `rc-1`

## `versions/1.21.11/1.21.11.jar` -> `1.21.11`. The folder is the version; the
## file inside it may be named anything and often is, for a modded install.
proc versionOf*(entry: string): string =
  result = ""
  var i = 0
  while i < entry.len and entry[i] != '/':
    result.add entry[i]
    inc i

proc stageOf(word: string): int =
  if word == "rc": 2
  elif word == "pre": 1
  elif word == "snapshot" or word == "w" or word == "experimental": 0
  else: -1

## A version name, in a shape two of them can be compared in.
proc rankVersion*(name: string): Version =
  result = Version(name: name, parts: @[], stage: 3, order: 0)
  var word = ""
  var number = 0
  var digits = false
  var i = 0
  while i <= name.len:
    if i == name.len or name[i] == '.' or name[i] == '-':
      if digits:
        if result.stage == 3: result.parts.add number
        else: result.order = number
      elif word.len > 0:
        let s = stageOf(word)
        if s >= 0 and result.stage == 3:
          result.stage = s
          result.order = 0
      word = ""
      number = 0
      digits = false
    elif name[i] >= '0' and name[i] <= '9':
      number = number * 10 + (int(name[i]) - int('0'))
      digits = true
      word.add name[i]
    else:
      var c = name[i]
      if c >= 'A' and c <= 'Z': c = char(int(c) + 32)
      word.add c
      digits = false
    inc i

## Is `a` the newer of the two? Numbers first, component by component with a
## missing component counting as zero, then the stage, then its own number.
proc newer*(a, b: Version): bool =
  var i = 0
  var most = a.parts.len
  if b.parts.len > most: most = b.parts.len
  while i < most:
    let x = if i < a.parts.len: a.parts[i] else: 0
    let y = if i < b.parts.len: b.parts[i] else: 0
    if x != y: return x > y
    inc i
  if a.stage != b.stage: return a.stage > b.stage
  a.order > b.order

## The index of the entry for version `want`, or -1 when no folder is that
## version. Exact, on the folder name, because that is the name the launcher
## writes and the name a player reads back off the screen.
proc jarNamed*(entries: seq[string]; want: string): int =
  result = -1
  if want.len == 0: return result
  var i = 0
  while i < entries.len:
    if versionOf(entries[i]) == want: return i
    inc i

## Which of those jar entries is the one to read. -1 when there are none.
##
## **`prefer` wins over newest, and that is the whole rule.** The assets and the
## protocol client are one thing and not two: `aoughwl.mcnet` speaks
## protocol 774, which is 1.21.11's wire, and a block set taken out of a
## different version is a client whose blocks are not the server's. Newest-with-
## a-jar was the rule when nothing else in this game had an opinion; something
## does now, so the version the rest of the stack targets is asked for by name
## and the old rule is what answers when that version is not installed.
##
## `prefer` empty asks for nothing and leaves the old rule in charge, which is
## what every caller that has no target does.
proc chooseJar*(entries: seq[string]; prefer = ""): int =
  result = jarNamed(entries, prefer)
  if result >= 0: return result
  var best = Version(name: "", parts: @[], stage: -1, order: -1)
  var i = 0
  while i < entries.len:
    let here = rankVersion(versionOf(entries[i]))
    if result < 0 or newer(here, best):
      result = i
      best = here
    inc i

## The resource-pack format a jar speaks, out of its own `version.json`.
##
## `pack_version.resource_major` is the modern spelling; `pack_version.resource`
## is what it was called before the major/minor split; `pack_format` is what a
## `pack.mcmeta` calls the same number, and is read as a fallback so that this
## works against either file.
proc jarPackFormat*(doc: Json): int =
  if doc.root < 0: return 0
  let pv = member(doc, doc.root, "pack_version")
  if pv >= 0:
    let major = int(number(doc, member(doc, pv, "resource_major"), 0.0))
    if major > 0: return major
    let plain = int(number(doc, member(doc, pv, "resource"), 0.0))
    if plain > 0: return plain
  let pack = member(doc, doc.root, "pack")
  if pack >= 0:
    return int(number(doc, member(doc, pack, "pack_format"), 0.0))
  int(number(doc, member(doc, doc.root, "pack_format"), 0.0))

## Whether a pack declaring `low`..`high` covers a jar speaking `format`. A pack
## that declared nothing at all covers everything - refusing on a missing number
## helps nobody, which is the rule `readPackMeta` already follows.
proc fitsPack*(format, low, high: int): bool =
  if format <= 0 or high <= 0: return true
  if format > high: return false
  if low > 0 and format < low: return false
  true

## The version whose id a jar entry carries, for a message.
proc jarName*(entry: string): string =
  result = entry
  var i = entry.len - 1
  while i >= 0:
    if entry[i] == '/':
      result = ""
      var j = i + 1
      while j < entry.len:
        result.add entry[j]
        inc j
      return result
    dec i

## The escape a value carries over the boundary, so that a value with a newline
## in it - and language files have them - survives being one line.
## `mcui/mcuilang.unescapeValue` is the other half and the test round-trips it.
proc escapeLangValue*(text: string): string =
  result = ""
  var i = 0
  while i < text.len:
    let c = text[i]
    if c == '\\': result.add "\\\\"
    elif c == '\n': result.add "\\n"
    elif c == '\t': result.add "\\t"
    else: result.add c
    inc i

## A modern `lang/<code>.json`, which is one flat object of strings, as the flat
## table. Anything in it that is not a string is skipped rather than guessed at.
## How many rows `flattenLang` would produce - the object's own member count,
## which is what a caller folding it in a few rows at a time counts against.
proc langKeyCount*(doc: Json): int =
  if doc.root < 0 or kindAt(doc, doc.root) != jObject: return 0
  len(doc, doc.root)

## Rows `from0` up to `from0 + count` of that same table, and nothing else.
##
## The whole file at once was a four-second frame - see `aoughwl.minecraft`
## main.nim's `stepLang` for the measurement - so the caller walks it a budget
## at a time and this is the slice it asks for. `flattenLang` below is this over
## the whole range and the test holds the two to the same answer.
proc flattenLangRows*(doc: Json; from0, count: int): string =
  result = ""
  if doc.root < 0 or kindAt(doc, doc.root) != jObject: return result
  let n = len(doc, doc.root)
  var i = from0
  if i < 0: i = 0
  var last = from0 + count
  if last > n: last = n
  while i < last:
    let node = item(doc, doc.root, i)
    inc i
    if node < 0 or kindAt(doc, node) != jString: continue
    let key = keyAt(doc, node)
    if key.len == 0: continue
    result.add key
    result.add "\t"
    result.add escapeLangValue(text(doc, node))
    result.add "\n"

proc flattenLang*(doc: Json): string =
  flattenLangRows(doc, 0, langKeyCount(doc))

## The pre-1.13 spelling: `en_US.lang`, one `key=value` a line, `#` for a
## comment. Same table out, so the caller never learns which one it got.
proc flattenLegacyLang*(body: string): string =
  result = ""
  var line = ""
  var i = 0
  while i <= body.len:
    if i == body.len or body[i] == '\n':
      var key = ""
      var j = 0
      while j < line.len and line[j] != '=':
        if line[j] != '\r': key.add line[j]
        inc j
      if key.len > 0 and key[0] != '#' and j < line.len:
        var value = ""
        var k = j + 1
        while k < line.len:
          if line[k] != '\r': value.add line[k]
          inc k
        result.add key
        result.add "\t"
        result.add escapeLangValue(value)
        result.add "\n"
      line = ""
    else:
      line.add body[i]
    inc i

# ---------------------------------------------------------------------------
# How big a picture is, without decoding it
#
# The interface has to be laid out in the pixels the *game* lays out in - a
# hotbar is 182 by 22 - and there is no host call anywhere that asks a picture
# its size. `mcui` cannot answer it either: it has no PNG reader and must not
# grow one. So the size comes over the same seam the font's measurements do,
# and it is read here, out of the thirteenth byte onwards of the file, which is
# where every PNG in the world keeps it.
#
# Not `decodePng`. A 64x pack's `inventory.png` is a megabyte of pixels nobody
# wants; the header is twenty-four bytes and the answer is in it.
#
# **The jar's file, not the pack's.** A 64x pack's `hotbar.png` measures 728 by
# 88 and the game still draws it 182 by 22, because the size in the blit is the
# game's and the picture is only stretched onto it. Taking the size off the
# topmost layer would move every rectangle on the screen the moment somebody
# turned a pack on, so the caller looks this up in the jar layer alone. That is
# the same distinction `mcuisprite` calls *nominal*.

const PngMagic = [137, 80, 78, 71, 13, 10, 26, 10]

proc be32At(d: seq[int]; at: int): int =
  if at + 3 >= d.len: return -1
  ((d[at] and 255) shl 24) or ((d[at + 1] and 255) shl 16) or
    ((d[at + 2] and 255) shl 8) or (d[at + 3] and 255)

## `@[width, height]`, or `@[]` when this is not a PNG. Twenty-four bytes read
## and nothing decoded.
proc pngSize*(data: seq[int]): seq[int] =
  result = @[]
  if data.len < 24: return result
  var i = 0
  while i < PngMagic.len:
    if (data[i] and 255) != PngMagic[i]: return result
    inc i
  # Bytes 12..15 are the chunk name and the first chunk of a PNG is IHDR.
  if data[12] != int('I') or data[13] != int('H') or data[14] != int('D') or
     data[15] != int('R'): return result
  let w = be32At(data, 16)
  let h = be32At(data, 20)
  if w <= 0 or h <= 0: return result
  @[w, h]

## The line one picture's size goes over the boundary as. `mcui/mcuihud.sizeIn`
## is the other half and the test round-trips it.
proc sizeLine*(name: string; width, height: int): string =
  name & "\t" & $width & "\t" & $height & "\n"
