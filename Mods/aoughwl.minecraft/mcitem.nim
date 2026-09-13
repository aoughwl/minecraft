## Item models: the other half of the game's art, and the one a HUD needs.
##
## Pure: nothing here calls the host.
##
## An item model is a block model's file format with a different ending. Three
## endings, in fact, and telling them apart is the whole of this file.
##
## **A block item.** `item/stone.json` is `{"parent": "block/stone"}` and there
## is nothing more to it: the item is the block, drawn small. `mcmodel` already
## bakes it and this file has nothing to add.
##
## **`builtin/generated`.** `item/apple.json` is
## `{"parent": "item/generated", "textures": {"layer0": "item/apple"}}`, and
## `item/generated` is `{"parent": "builtin/generated"}`. There is no geometry
## anywhere in that chain, because Minecraft *builds* it: the picture is a flat
## sheet a sixteenth of a block thick, and every layer is another sheet in front
## of the last. `generatedJson` writes that model out as ordinary JSON so the
## same tested bake, the same atlas and the same uv rules do the work - there is
## no second geometry path here and there must never be one.
##
## Minecraft goes one step further and extrudes the *outline* of the picture, so
## a sword seen edge-on is a sword-shaped ribbon rather than a rectangle. That
## is per-pixel work over the alpha channel and it is **not done**: the front
## and the back are emitted and the four edges are not, so an item viewed exactly
## edge-on is invisible rather than wrong. It is stated here, in the log and in
## `docs/MINECRAFT-IMPORT.md`, because a silent near-miss is the thing that gets
## noticed a year later.
##
## **`builtin/entity`.** A chest, a shulker box, a banner, a bed, a decorated
## pot. Minecraft draws these with a hard-coded entity renderer and the model
## file is a stub that says so. There is nothing to read, and a caller is told
## that rather than handed an empty mesh.
##
## ## Overrides and display
##
## `overrides` picks a different model by a predicate - a bow that bends as it
## is drawn, a clock, a compass. `display` says how the item is held. Both are
## read into nothing here: an icon and a dropped item want neither. `predicateOf`
## exists so a caller can *see* that a model has overrides and say so.

import mcjson
import mcmodel

const
  ItemBlock* = 0
    ## Its chain reaches real `elements`: bake it like any other model.
  ItemGenerated* = 1
    ## `builtin/generated`: the layers are the model.
  ItemEntity* = 2
    ## `builtin/entity`: the game draws it, there is no model.
  ItemUnknown* = 3

  MaxItemLayers* = 8
    ## Vanilla uses at most two - a potion and its overlay, a spawn egg. Eight
    ## is a resource pack being ambitious and still bounded.

## Which of the three a chain is. The chain is walked child-first and the first
## thing that settles it wins: real elements make it a block item however it is
## parented, because a pack may give an ordinary item a real model.
proc classifyItem*(docs: seq[Json]): int =
  if geometryLayer(docs) >= 0: return ItemBlock
  var i = 0
  while i < docs.len:
    let parent = parentOf(docs[i])
    if isBuiltin(parent):
      let path = resourcePath(parent)
      if path == "builtin/entity": return ItemEntity
      return ItemGenerated
    inc i
  ItemUnknown

## The layer textures, in order, resolved to files. `layer0` is the bottom sheet
## and each one after it sits a sixteenth of a block in front.
##
## The gap in the numbering is where it stops: a pack that defines `layer0` and
## `layer2` gets one layer, because layer 1 is the sheet that would have been
## behind layer 2 and guessing what belongs there is worse than stopping.
proc layersOf*(t: Textures): seq[string] =
  result = @[]
  var i = 0
  while i < MaxItemLayers:
    let name = resolveTexture(t, "#layer" & $i)
    if name.len == 0: return result
    result.add name
    inc i

## Whether this model hands off to another one by a predicate - a bow being
## drawn, a compass pointing. Read so a caller can say the icon is the resting
## form of something that has several, rather than pretending it has one.
proc predicateCount*(doc: Json): int =
  let node = member(doc, doc.root, "overrides")
  if node < 0 or kindAt(doc, node) != jArray: return 0
  len(doc, node)

## `n/16` as an exact decimal. A sixteenth is 0.0625, so four places is exact
## for every value this file writes, and nothing here goes through the
## interpreter's own idea of what a float looks like as text.
proc sixteenths*(n: int): string =
  result = $(n div 16)
  let rest = (n mod 16) * 625
  if rest == 0: return result
  result.add "."
  var digits = $rest
  var pad = 4 - digits.len
  while pad > 0:
    result.add "0"
    dec pad
  result.add digits

## The generated model, written as the JSON it is equivalent to.
##
## One thin box per layer, from z = 7.5 to 8.5 the way vanilla's own
## `item/generated` element is, with the north and south faces textured and the
## four edges left off. The layers step forward by a sixteenth so a potion's
## contents do not fight its bottle for the same plane.
##
## Handing back text rather than a `Bake` is deliberate: the bake, the uv
## derivation, the face winding and the palette all stay in `mcmodel`, proved
## once, and this file cannot quietly disagree with them.
proc generatedJson*(layers: seq[string]): string =
  if layers.len == 0: return ""
  result = "{\"textures\": {"
  var i = 0
  while i < layers.len:
    if i > 0: result.add ", "
    result.add "\"layer"
    result.add $i
    result.add "\": \""
    var j = 0
    while j < layers[i].len:
      # A texture name is a resource path: letters, digits, slashes, colons and
      # underscores. Anything that would need escaping in JSON cannot be in one,
      # and is dropped rather than written out to break the document.
      let c = layers[i][j]
      if c != '"' and c != '\\': result.add c
      inc j
    result.add "\""
    inc i
  result.add "}, \"elements\": ["
  i = 0
  while i < layers.len:
    if i > 0: result.add ", "
    # 7.5 + i/16 .. 8.5 + i/16. Written through `sixteenths` rather than through
    # `$` on a float, because what `$` makes of 7.5625 is the interpreter's
    # business and this string has to go back through a decimal parser exactly.
    result.add "{\"from\": [0, 0, "
    result.add sixteenths(120 + i)
    result.add "], \"to\": [16, 16, "
    result.add sixteenths(136 + i)
    result.add "], \"faces\": {\"north\": {\"texture\": \"#layer"
    result.add $i
    result.add "\"}, \"south\": {\"texture\": \"#layer"
    result.add $i
    result.add "\"}}}"
    inc i
  result.add "]}"

## The generated model, baked. The caller hands over the merged variable table
## the chain produced, exactly as it would for a block.
proc bakeGenerated*(layers: seq[string]): Bake =
  var t = Textures(keys: @[], vals: @[])
  var i = 0
  while i < layers.len:
    t.keys.add "layer" & $i
    t.vals.add layers[i]
    inc i
  let body = generatedJson(layers)
  if body.len == 0:
    result = Bake(count: 0, texture: @[], face: @[], tint: @[], cull: @[],
                  pos: @[], norm: @[], uv: @[],
                  problem: "this item names no layer0 texture", skipped: 0)
    return result
  let doc = parseJson(body)
  if doc.problem.len > 0:
    result = Bake(count: 0, texture: @[], face: @[], tint: @[], cull: @[],
                  pos: @[], norm: @[], uv: @[],
                  problem: "the generated model would not parse: " & doc.problem,
                  skipped: 0)
    return result
  bakeElements(doc, member(doc, doc.root, "elements"), t)

## Where an item's picture lives, from the item's own name. Items are one flat
## folder - `assets/minecraft/textures/item/<name>.png` - and an item whose
## model is a block has no picture of its own at all, which is why this is only
## ever asked after `classifyItem` said `ItemGenerated`.
proc itemTexturePath*(reference: string): string =
  "textures/" & resourcePath(reference) & ".png"

# ---------------------------------------------------------------------------
# Item definitions: where an item's model moved to
#
# Everything above reads a *model* - `assets/minecraft/models/item/<name>.json`
# - and that file is still there and still says what it always said. What went
# away is the guarantee that every item has one.
#
# Up to 1.21.3 every item in the game had a `models/item/<name>.json`, and a
# block item's was the one-line `{"parent": "minecraft:block/stone"}`. From
# 1.21.4 the mapping from an item to its model lives in a separate file,
# `assets/minecraft/items/<name>.json`, and the one-line stubs were deleted.
# Both of the jars this was measured against are past that line:
#
#     26.2      models/item 1271   items/ 1537   models/item/stone.json: no
#     1.21.11   models/item 1283   items/ 1505   models/item/stone.json: no
#
# So a reader that only knows `models/item/` finds nothing for 266 of the items
# in 26.2 - every block item, which is most of what a hotbar holds - and says
# nothing about it, because "no such file" and "this item has no model" are the
# same answer to it.
#
# **The choice is made on which file is there, never on a version number.** A
# caller looks for `items/<name>.json`; if a layer has one it reads it with
# `definitionModel`, and if none does it falls back to `item/<name>` as before.
# A resource pack for an old version, an old jar, and a modern jar therefore all
# work, and none of them is asked what version it claims to be - which is the
# rule the interface adopted after `gui/widgets.png` moved to `gui/sprites/`
# and the menu drew a placeholder for a day without saying so.
#
# ## The shape
#
# The root is `{"model": <node>}`. A node is tagged by `type`:
#
#     minecraft:model            names a model outright: 1390 of 26.2's 1537
#     minecraft:special          the game draws it; `base` is the flat model
#                                it is drawn on - a chest, a shield, a banner
#     everything else            a dispatch: select, condition, range_dispatch,
#                                composite, dye, bundle - one item with several
#                                appearances chosen at draw time
#
# A dispatch is walked for its *resting* form, the same thing `predicateCount`
# does for the old `overrides`: the fallback if it has one, then the first case.
# An icon and a dropped item want one model, and picking the first branch and
# saying how many there were beats refusing to draw a compass.

const
  MaxDefinitionDepth* = 8
    ## A dispatch nests - a select inside a composite inside a condition. Eight
    ## is deeper than anything vanilla ships and still a bound.

## Whether this document is an item *definition* rather than an item *model*.
## The two live in different folders and have no key in common: a definition's
## root is a single `model` object, a model's root is `parent`, `elements` or
## `textures`. This is what picks the reader.
proc isItemDefinition*(doc: Json): bool =
  let node = member(doc, doc.root, "model")
  node >= 0 and kindAt(doc, node) == jObject

## Whether this document is an item model of the older kind - the thing
## `chainOf` and `classifyItem` above know how to read.
proc isItemModel*(doc: Json): bool =
  if isItemDefinition(doc): return false
  member(doc, doc.root, "parent") >= 0 or
    member(doc, doc.root, "elements") >= 0 or
    member(doc, doc.root, "textures") >= 0

proc modelWithin(doc: Json; node, depth: int): string =
  if node < 0 or depth > MaxDefinitionDepth: return ""
  if kindAt(doc, node) != jObject: return ""
  let tag = text(doc, member(doc, node, "type"))
  if tag == "minecraft:model" or tag == "model":
    let named = member(doc, node, "model")
    if kindAt(doc, named) == jString: return text(doc, named)
  # `minecraft:special`. The lid, the hinge or the banner cloth is the entity
  # renderer's business - the same case `ItemEntity` covers above - but `base`
  # is a real model file and drawing it is better than drawing nothing.
  let base = member(doc, node, "base")
  if kindAt(doc, base) == jString: return text(doc, base)
  # A dispatch. The resting form first: what the item looks like when nothing
  # about it is unusual.
  var pick = modelWithin(doc, member(doc, node, "fallback"), depth + 1)
  if pick.len > 0: return pick
  pick = modelWithin(doc, member(doc, node, "on_false"), depth + 1)
  if pick.len > 0: return pick
  pick = modelWithin(doc, member(doc, node, "on_true"), depth + 1)
  if pick.len > 0: return pick
  # Then the branches, in the order they are written. `cases` and `entries`
  # wrap each branch in `{"model": ..., "when": ...}`; `composite`'s `models`
  # is a bare list of nodes. Both are tried on every entry, because which one
  # it is is the entry's own business.
  const Lists = ["cases", "entries", "models"]
  var l = 0
  while l < 3:
    let list = member(doc, node, Lists[l])
    inc l
    if kindAt(doc, list) != jArray: continue
    var i = 0
    while i < len(doc, list):
      let entry = item(doc, list, i)
      inc i
      pick = modelWithin(doc, member(doc, entry, "model"), depth + 1)
      if pick.len > 0: return pick
      pick = modelWithin(doc, entry, depth + 1)
      if pick.len > 0: return pick
  ""

## The model an item definition names, or "" when nothing in it does. An old
## item model read through here answers "", which is the visible failure that
## keeps the two readers from being mistaken for each other.
proc definitionModel*(doc: Json): string =
  modelWithin(doc, member(doc, doc.root, "model"), 0)

## How many appearances the definition dispatches between at the top level, so a
## caller can say the icon is the resting one of several rather than pretending
## it is the only one. A plain `minecraft:model` answers 0, the same as an item
## model with no `overrides`.
proc definitionCases*(doc: Json): int =
  let node = member(doc, doc.root, "model")
  if kindAt(doc, node) != jObject: return 0
  let tag = text(doc, member(doc, node, "type"))
  if tag == "minecraft:model" or tag == "model": return 0
  var total = 0
  const Lists = ["cases", "entries", "models"]
  var l = 0
  while l < 3:
    let list = member(doc, node, Lists[l])
    inc l
    if kindAt(doc, list) == jArray: total = total + len(doc, list)
  if member(doc, node, "fallback") >= 0: total = total + 1
  total

## Where an item definition lives, from the item's own name. One flat folder,
## beside `models/` rather than inside it.
proc itemDefinitionPath*(name: string): string =
  "items/" & resourcePath(name) & ".json"
