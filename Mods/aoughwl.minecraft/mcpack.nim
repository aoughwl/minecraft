## Resource packs, stacked over the jar.
##
## Pure: nothing here calls the host. What it decides is *which path to try
## first*; who opens a file is `main.nim`'s business.
##
## A resource pack is the same tree as the jar - `assets/<namespace>/textures/...`,
## `assets/<namespace>/models/...` - carrying only the files it replaces. The
## rule is one sentence: **the highest pack that has the file wins, and the jar
## is the bottom of the stack.** Everything else here is that sentence with the
## edge cases spelled out.
##
## The edge cases are real. A pack that replaces `block/stone.png` and nothing
## else must not hide `block/dirt.png`. A pack that replaces a *model* changes
## the parent chain, so the chain has to be walked through the stack rather than
## resolved in the jar and then patched. And a pack that ships a font and no
## textures must not cost a lookup per texture - which is why `Layers` holds
## roots and not a file list, and why the answer to "where is this" is a short
## list of candidates in priority order rather than an index of the world.
##
## ## `pack.mcmeta`
##
##     {"pack": {"pack_format": 34, "description": "My pack"}}
##
## `pack_format` is Minecraft's own number for the layout the pack was written
## against, and it moves nearly every version. It is read and reported and it is
## **not** enforced: this reader does not care where a pack thinks `textures/`
## lives, because it looks for the file it wants and takes the first one that is
## there. A refusal on a version number would reject packs that work.
##
## The one thing the format number does change is the folder a *block texture*
## lives in. Before format 4 (Minecraft 1.13) textures were `textures/blocks/`
## and `textures/items/`, plural, and models named them without the `block/`
## prefix. `candidates` offers both spellings, oldest last, so a pack from 2014
## still resolves and a modern one pays one failed lookup for the pleasure.

import mcjson

const
  MaxLayers* = 16
    ## A stack deeper than this is a player who has enabled every pack they own,
    ## and every lookup would walk all of it.

type
  PackInfo* = object
    format*: int         ## the newest format this pack claims, or 0
    lowest*: int         ## `min_format`, or the same as `format`
    description*: string
    problem*: string

  Layers* = object
    ## Where to look, highest priority first. A root is a folder prefix that a
    ## path is hung off - `Imported/packs/faithful/` over `Imported/` - and the
    ## last one is the jar.
    root*: seq[string]
    label*: seq[string]

proc noLayers*(): Layers = Layers(root: @[], label: @[])

## Read a `pack.mcmeta`. A pack with no readable one is still a pack - the
## description is empty and the format is zero - because the files are what
## matter and refusing on a missing metadata file helps nobody.
##
## **The format is a range now, and often only a range.** A pack used to say
## `"pack_format": 15` and one number was the whole of it. A pack that means to
## work across several versions says `"min_format": 79, "max_format": 100` and
## may not carry `pack_format` at all - Faithful 64x does exactly this - so a
## reader that only knows the single field reads such a pack as format 0 and
## anything that gated on the number would quietly refuse a pack that is right
## there and working. Both spellings are read here, the top of the range is what
## `format` answers, and `lowest` carries the bottom of it.
proc readPackMeta*(doc: Json): PackInfo =
  result = PackInfo(format: 0, lowest: 0, description: "", problem: "")
  if doc.root < 0:
    result.problem = "pack.mcmeta would not parse"
    return result
  let pack = member(doc, doc.root, "pack")
  if pack < 0:
    result.problem = "pack.mcmeta has no 'pack' object"
    return result
  result.format = int(number(doc, member(doc, pack, "pack_format"), 0.0))
  let low = int(number(doc, member(doc, pack, "min_format"), 0.0))
  let high = int(number(doc, member(doc, pack, "max_format"), 0.0))
  if high > result.format: result.format = high
  result.lowest = low
  if result.lowest == 0: result.lowest = result.format
  if result.format == 0: result.format = result.lowest
  let desc = member(doc, pack, "description")
  if kindAt(doc, desc) == jString:
    result.description = text(doc, desc)
  elif kindAt(doc, desc) == jObject:
    # A description may be a chat component. The `text` of it is the readable
    # part and everything else in there is colour.
    result.description = text(doc, member(doc, desc, "text"))
  elif kindAt(doc, desc) == jArray:
    var i = 0
    while i < len(doc, desc):
      let piece = item(doc, desc, i)
      if kindAt(doc, piece) == jString: result.description.add text(doc, piece)
      else: result.description.add text(doc, member(doc, piece, "text"))
      inc i

## Put a pack on top of the stack. The first one added is the highest, so a
## caller adds the player's packs in the order Minecraft lists them - topmost
## first - and the jar last.
proc addLayer*(l: var Layers; root, label: string): bool =
  if l.root.len >= MaxLayers: return false
  var r = root
  if r.len > 0 and r[r.len - 1] != '/': r.add "/"
  l.root.add r
  l.label.add label
  true

proc layerCount*(l: Layers): int = l.root.len

## `textures/block/x.png` as Minecraft spelled it before 1.13, or "" when the
## path is not one of the two folders that were renamed.
proc oldSpelling*(path: string): string =
  const Was = ["textures/block/", "textures/item/"]
  const Now = ["textures/blocks/", "textures/items/"]
  var w = 0
  while w < 2:
    let head = Was[w]
    if path.len > head.len:
      var same = true
      var i = 0
      while i < head.len:
        if path[i] != head[i]:
          same = false
          break
        inc i
      if same:
        result = Now[w]
        var j = head.len
        while j < path.len:
          result.add path[j]
          inc j
        return result
    inc w
  ""

## Where a resource might be, highest layer first.
##
## `path` is the part after the namespace folder - `textures/block/stone.png`,
## `models/block/stone.json` - and `namespace` is `minecraft` unless a pack's
## own model named another one. `format` is the *reader's* oldest supported
## layout: pass 0 to also offer the pre-1.13 plural spellings, which is what a
## caller does when it has no reason to think the pack is modern.
proc candidates*(l: Layers; namespace, path: string; alsoOld = true): seq[string] =
  result = @[]
  var i = 0
  while i < l.root.len:
    result.add l.root[i] & "assets/" & namespace & "/" & path
    inc i
  if not alsoOld: return result
  # The pre-1.13 spelling: `textures/blocks/x.png` for `textures/block/x.png`.
  # Offered after every modern candidate, so a modern pack never pays for it
  # until the file is genuinely missing everywhere.
  let old = oldSpelling(path)
  if old.len == 0: return result
  i = 0
  while i < l.root.len:
    result.add l.root[i] & "assets/" & namespace & "/" & old
    inc i

## Which layer a path came from, for a log line that says *which pack* replaced
## a texture. -1 when it is under none of them.
proc layerOf*(l: Layers; path: string): int =
  var i = 0
  while i < l.root.len:
    if path.len >= l.root[i].len:
      var same = true
      var j = 0
      while j < l.root[i].len:
        if path[j] != l.root[i][j]:
          same = false
          break
        inc j
      if same: return i
    inc i
  -1

# ---------------------------------------------------------------------------
# Which packs the player actually turned on
#
# `options.txt`, beside the saves folder, carries the answer:
#
#   resourcePacks:["vanilla","file/Faithful.zip","file/my folder"]
#
# It is the player's own selection, in Minecraft's own priority order - and
# that order is *last is highest*, which is the opposite of the order this file
# stacks layers in, so `enabledPacks` hands them back already reversed. Reading
# it is the difference between honouring the player's choice and applying every
# pack they have ever downloaded.
#
# `vanilla` is the jar itself and is dropped: the jar is the bottom layer here
# whatever the file says. `file/` is Minecraft's prefix for a pack in the
# `resourcepacks` folder and is taken off, leaving the file or folder name.

## The value of one `key:value` line, or "" when the text has no such line.
## `options.txt` is a flat file of them and nothing here needs more than that.
proc optionLine*(body, key: string): string =
  var line = ""
  var i = 0
  while i <= body.len:
    if i == body.len or body[i] == '\n':
      var head = ""
      var j = 0
      while j < line.len and line[j] != ':':
        head.add line[j]
        inc j
      if head == key and j < line.len:
        result = ""
        var k = j + 1
        while k < line.len:
          if line[k] != '\r': result.add line[k]
          inc k
        return result
      line = ""
    else:
      line.add body[i]
    inc i
  ""

## The packs the player has enabled, highest priority first.
##
## Minecraft writes the list lowest first, so this reverses it, and it drops
## `vanilla` and anything else with no `file/` in front of it - those are the
## jar and the built-in packs, which are not layers a player supplied.
proc enabledPacks*(body: string): seq[string] =
  result = @[]
  let list = optionLine(body, "resourcePacks")
  var names: seq[string] = @[]
  var piece = ""
  var inside = false
  var i = 0
  while i < list.len:
    let c = list[i]
    if c == '"':
      if inside:
        names.add piece
        piece = ""
      inside = not inside
    elif inside:
      piece.add c
    inc i
  i = names.len - 1
  while i >= 0:
    let name = names[i]
    dec i
    if name.len <= 5: continue
    var head = ""
    var j = 0
    while j < 5:
      head.add name[j]
      inc j
    if head != "file/": continue
    var rest = ""
    j = 5
    while j < name.len:
      rest.add name[j]
      inc j
    if rest.len > 0: result.add rest

## The folder one pack's files are extracted into, under the mod's own folder.
## The name is used as it stands, minus anything that would leave the folder:
## a pack called `../../secrets` must not become one.
proc packFolder*(dest, name: string): string =
  result = dest & "/packs/"
  var i = 0
  while i < name.len:
    let c = name[i]
    if c == '/' or c == '\\' or c == ':' or c == '.': result.add "_"
    else: result.add c
    inc i
