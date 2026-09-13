## An item stack on the wire, and the thing that makes it hard: components.
##
## Since 1.20.5 a stack is no longer an id, a count and a lump of NBT. It is an
## id, a count, and a list of **data components** - typed, versioned, one
## registry entry each - where the server sends only those that *differ from the
## item defaults*. That change is why `Slot` is the largest shared type in the
## protocol and why it is in its own file: `set_slot`, `container_set_content`,
## `set_equipment` and entity metadata all carry one, so a Play decoder that
## cannot find the end of a stack cannot find the end of any of them.
##
## THE HARD PART IS NOT UNDERSTANDING A COMPONENT, IT IS SKIPPING ONE. There is
## no length prefix on a component body. To get past a component you do not care
## about you must know its shape exactly, and there are **104 of them at
## protocol 774**. So this file separates the two jobs:
##
##   * `readSlot` walks a stack and records, for every component, its type and
##     the **byte span** its body occupies. It has to know each shape well
##     enough to advance, and nothing more.
##   * the small readers below turn one recorded span into values, and a caller
##     asks only for the components it cares about.
##
## That split is what keeps this file finite. It also means an unparsed
## component costs nothing: the bytes are still there and a later version of
## this file can read them without the decoder above changing.
##
## COMPONENT IDS ARE NOT HARDCODED, and this is the same rule the packet table
## follows. A component type is a numeric id into the `minecraft:data_component_type`
## registry, and that registry is ordered by the games own declaration order, so
## the numbers move between versions exactly as packet ids do. `Components` is a
## table a caller fills from the players own `registries.json`; dispatch is on
## the **name**. With no table loaded, `readSlot` refuses a stack that carries
## components rather than guessing what they are - which is the honest failure,
## because the alternative is to advance by the wrong number of bytes and decode
## the rest of the packet as plausible nonsense.
##
## WHAT IS NOT IMPLEMENTED, NAMED RATHER THAN HIDDEN. `KnownShapes` below covers
## the components whose bodies are a scalar, a string, an NBT value, a list of
## NBT values, a nested stack, or one of nine hand-written shapes. The rest -
## `food`, `tool`, `equippable`, `written_book_content`, `profile`, `fireworks`,
## `trim`, `instrument`, `lodestone_tracker`, `banner_patterns`, `bees` and the
## others listed in `refusalFor` - are **refused, loudly, by name**. A refusal
## stops the stream; a guess would not, and would be worse. Adding one is adding
## a row to `shapeOf` and a case to `skipShape`.

import netwire
import netnbt

const
  # The shapes a component body can have. These are not wire values - they are
  # this file own vocabulary for "how many bytes is that, then".
  ShapeUnknown* = 0
  ShapeVoid* = 1
  ShapeVarInt* = 2
  ShapeString* = 3
  ShapeBool* = 4
  ShapeFloat* = 5
  ShapeInt* = 6
  ShapeLong* = 7
  ShapeByte* = 8
  ShapeNbt* = 9
  ShapeNbtList* = 10
  ShapeSlot* = 11
  ShapeEnchantments* = 12
  ShapeAttributeModifiers* = 13
  ShapeSlotList* = 14
  ShapeBlockState* = 15
  ShapeTooltipDisplay* = 16
  ShapeCustomModelData* = 17

  MaxComponents* = 256
    ## A stack that claims more components than the registry has entries is not
    ## a stack. Vanilla never sends more than a handful.
  MaxNestedSlots* = 8
    ## A bundle inside a shulker box inside a bundle is legal; a stack nested
    ## this deep is a loop. The depth is carried rather than assumed because
    ## `container`, `bundle_contents` and `charged_projectiles` all recurse.

type
  ComponentTable* = object
    ## id -> name, filled from the players own `registries.json`.
    names*: seq[string]

  Span* = object
    typeId*: int
    name*: string
    at*, len*: int      ## into the readers own `data`

  SlotItem* = object
    empty*: bool
    count*: int
    itemId*: int
    added*: seq[Span]
    removed*: seq[int]  ## component type ids the stack turns *off*

proc emptyComponents*(): ComponentTable =
  ComponentTable(names: @[])

proc declareComponent*(t: var ComponentTable; id: int; name: string) =
  if id < 0 or id > 4096: return
  while t.names.len <= id: t.names.add ""
  t.names[id] = name

proc componentName*(t: ComponentTable; id: int): string =
  if id < 0 or id >= t.names.len: "" else: t.names[id]

proc componentId*(t: ComponentTable; name: string): int =
  var i = 0
  while i < t.names.len:
    if t.names[i] == name: return i
    inc i
  result = -1

proc loaded*(t: ComponentTable): bool = t.names.len > 0

# ---------------------------------------------------------------------------
# The shape table
#
# Every row here was read out of the 774 type definitions rather than
# remembered. The ones that are a single scalar are the bulk of the registry,
# and the nine hand-written shapes below them are the ones a survival inventory
# actually carries: damage and enchantments on a tool, lore and a custom name on
# anything renamed, the contents of a shulker box or a bundle, and the block
# state on a placed-block item.

proc shapeOf*(name: string): int =
  case name
  of "minecraft:unbreakable", "minecraft:creative_slot_lock",
     "minecraft:intangible_projectile", "minecraft:glider":
    ShapeVoid
  of "minecraft:max_stack_size", "minecraft:max_damage", "minecraft:damage",
     "minecraft:rarity", "minecraft:repair_cost", "minecraft:enchantable",
     "minecraft:map_id", "minecraft:map_post_processing",
     "minecraft:ominous_bottle_amplifier", "minecraft:base_color",
     "minecraft:villager/variant", "minecraft:wolf/variant",
     "minecraft:wolf/sound_variant", "minecraft:wolf/collar",
     "minecraft:fox/variant", "minecraft:salmon/size",
     "minecraft:parrot/variant", "minecraft:tropical_fish/pattern",
     "minecraft:tropical_fish/base_color",
     "minecraft:tropical_fish/pattern_color", "minecraft:mooshroom/variant",
     "minecraft:rabbit/variant", "minecraft:pig/variant",
     "minecraft:cow/variant", "minecraft:frog/variant",
     "minecraft:horse/variant", "minecraft:llama/variant",
     "minecraft:axolotl/variant", "minecraft:cat/variant",
     "minecraft:cat/collar", "minecraft:sheep/color",
     "minecraft:shulker/color":
    ShapeVarInt
  of "minecraft:item_model", "minecraft:damage_resistant",
     "minecraft:tooltip_style", "minecraft:provides_banner_patterns",
     "minecraft:note_block_sound":
    ShapeString
  of "minecraft:enchantment_glint_override":
    ShapeBool
  of "minecraft:minimum_attack_charge", "minecraft:potion_duration_scale":
    ShapeFloat
  of "minecraft:dyed_color", "minecraft:map_color":
    ShapeInt
  of "minecraft:custom_data", "minecraft:custom_name", "minecraft:item_name",
     "minecraft:map_decorations", "minecraft:debug_stick_state",
     "minecraft:bucket_entity_data", "minecraft:recipes", "minecraft:lock",
     "minecraft:container_loot":
    ShapeNbt
  of "minecraft:lore":
    ShapeNbtList
  of "minecraft:use_remainder":
    ShapeSlot
  of "minecraft:enchantments", "minecraft:stored_enchantments":
    ShapeEnchantments
  of "minecraft:attribute_modifiers":
    ShapeAttributeModifiers
  of "minecraft:charged_projectiles", "minecraft:bundle_contents",
     "minecraft:container":
    ShapeSlotList
  of "minecraft:block_state":
    ShapeBlockState
  of "minecraft:tooltip_display":
    ShapeTooltipDisplay
  of "minecraft:custom_model_data":
    ShapeCustomModelData
  else:
    ShapeUnknown

proc refusalFor*(name: string): string =
  ## The message a refusal carries. Naming the component is the point: the fix
  ## for every one of these is a row in `shapeOf` and a branch in `skipShape`,
  ## and a message that said only "unknown component" would not say which.
  if name.len == 0:
    "a component whose type is not in the loaded registry"
  else:
    "no shape is implemented for the component " & name

# ---------------------------------------------------------------------------
# Walking a body

proc skipShape(r: var Reader; t: ComponentTable; shape, depth: int)

proc readSlotAt(r: var Reader; t: ComponentTable; depth: int): SlotItem

proc skipShape(r: var Reader; t: ComponentTable; shape, depth: int) =
  if not ok(r): return
  case shape
  of ShapeVoid:
    discard
  of ShapeVarInt:
    discard readVarInt(r)
  of ShapeString:
    discard readString(r)
  of ShapeBool, ShapeByte:
    discard readByte(r)
  of ShapeFloat, ShapeInt:
    discard readUInt(r)
  of ShapeLong:
    discard readLong(r)
  of ShapeNbt:
    let v = readNbt(r)
    if v.problem.len > 0: fail(r, v.problem)
  of ShapeNbtList:
    let n = readVarInt(r)
    if not ok(r): return
    if n < 0 or n > MaxComponents:
      fail(r, "a component list length is out of range")
      return
    var i = 0
    while i < n:
      let v = readNbt(r)
      if v.problem.len > 0:
        fail(r, v.problem)
        return
      inc i
  of ShapeSlot:
    discard readSlotAt(r, t, depth + 1)
  of ShapeSlotList:
    let n = readVarInt(r)
    if not ok(r): return
    if n < 0 or n > 1024:
      fail(r, "a nested stack list length is out of range")
      return
    var i = 0
    while i < n:
      discard readSlotAt(r, t, depth + 1)
      if not ok(r): return
      inc i
  of ShapeEnchantments:
    let n = readVarInt(r)
    if not ok(r): return
    if n < 0 or n > 1024:
      fail(r, "an enchantment list length is out of range")
      return
    var i = 0
    while i < n:
      discard readVarInt(r)        # enchantment id
      discard readVarInt(r)        # level
      inc i
  of ShapeAttributeModifiers:
    let n = readVarInt(r)
    if not ok(r): return
    if n < 0 or n > 1024:
      fail(r, "an attribute modifier list length is out of range")
      return
    var i = 0
    while i < n:
      discard readVarInt(r)        # attribute type id
      discard readString(r)        # modifier id
      discard readLong(r)          # value, an f64 read as its eight bytes
      discard readVarInt(r)        # operation
      discard readVarInt(r)        # equipment slot group
      let display = readVarInt(r)  # 0 default, 1 hidden, 2 override
      if not ok(r): return
      if display == 2:
        let v = readNbt(r)
        if v.problem.len > 0:
          fail(r, v.problem)
          return
      inc i
  of ShapeBlockState:
    let n = readVarInt(r)
    if not ok(r): return
    if n < 0 or n > 1024:
      fail(r, "a block state property list length is out of range")
      return
    var i = 0
    while i < n:
      discard readString(r)
      discard readString(r)
      inc i
  of ShapeTooltipDisplay:
    discard readByte(r)            # hideTooltip
    let n = readVarInt(r)
    if not ok(r): return
    if n < 0 or n > 1024:
      fail(r, "a hidden component list length is out of range")
      return
    var i = 0
    while i < n:
      discard readVarInt(r)
      inc i
  of ShapeCustomModelData:
    # Four arrays back to back: floats, flags, strings, colours. Reading three
    # of the four is the kind of mistake that leaves the stream one array short
    # and every later slot plausible and wrong, so all four are here.
    var k = 0
    while k < 4:
      let n = readVarInt(r)
      if not ok(r): return
      if n < 0 or n > 1024:
        fail(r, "a custom model data array length is out of range")
        return
      var i = 0
      while i < n:
        if k == 0: discard readUInt(r)
        elif k == 1: discard readByte(r)
        elif k == 2: discard readString(r)
        else: discard readUInt(r)
        inc i
      inc k
  else:
    fail(r, "a component shape this reader does not know")

# ---------------------------------------------------------------------------
# The stack itself

proc emptySlot*(): SlotItem =
  SlotItem(empty: true, count: 0, itemId: 0, added: @[], removed: @[])

proc readSlotAt(r: var Reader; t: ComponentTable; depth: int): SlotItem =
  result = emptySlot()
  if not ok(r): return
  if depth > MaxNestedSlots:
    fail(r, "stacks nested deeper than this reader will follow")
    return
  let count = readVarInt(r)
  if not ok(r): return
  if count <= 0:
    # Count zero is the empty stack, and it is the *whole* packet field: no id
    # and no components follow. A decoder that read an id anyway would be two
    # bytes into the next field on every empty inventory slot, which is most of
    # them.
    result.empty = true
    result.count = 0
    return
  result.empty = false
  result.count = count
  result.itemId = readVarInt(r)
  let addedCount = readVarInt(r)
  let removedCount = readVarInt(r)
  if not ok(r): return
  if addedCount < 0 or addedCount > MaxComponents or
     removedCount < 0 or removedCount > MaxComponents:
    fail(r, "a component count is out of range")
    return
  if (addedCount > 0 or removedCount > 0) and not loaded(t):
    fail(r, "a stack carries components and no component registry is loaded")
    return
  var i = 0
  while i < addedCount:
    let typeId = readVarInt(r)
    if not ok(r): return
    let name = componentName(t, typeId)
    let shape = shapeOf(name)
    if shape == ShapeUnknown:
      fail(r, refusalFor(name))
      return
    let bodyAt = r.at
    skipShape(r, t, shape, depth)
    if not ok(r): return
    result.added.add Span(typeId: typeId, name: name, at: bodyAt,
                          len: r.at - bodyAt)
    inc i
  i = 0
  while i < removedCount:
    let typeId = readVarInt(r)
    if not ok(r): return
    result.removed.add typeId
    inc i

proc readSlot*(r: var Reader; t: ComponentTable): SlotItem =
  readSlotAt(r, t, 0)

proc readUntrustedSlot*(r: var Reader; t: ComponentTable): SlotItem =
  ## What the client sends back in `set_creative_mode_slot`. The wire shape is
  ## the same; only the trust the server places in it differs, and that is the
  ## servers problem rather than this readers.
  readSlotAt(r, t, 0)

proc componentSpan*(s: SlotItem; name: string): int =
  ## Index into `added`, or -1. A caller asks for the one component it wants.
  var i = 0
  while i < s.added.len:
    if s.added[i].name == name: return i
    inc i
  result = -1

proc spanReader*(r: Reader; s: Span): Reader =
  ## A reader over one recorded component body, so that the small readers below
  ## cannot run off the end of their own component and into the next one.
  readerFrom(r.data, s.at, s.at + s.len)

# ---------------------------------------------------------------------------
# Turning a recorded span into values, for the components a game actually asks
# about. Each of these is over a *bounded* reader, so a shape that turned out to
# be wrong shows up as a refusal here rather than as corruption later.

proc damageOf*(r: Reader; s: SlotItem): int =
  ## Durability used, or 0 when the stack carries no `damage` component - which
  ## is what an undamaged tool sends, because the server sends only differences.
  let at = componentSpan(s, "minecraft:damage")
  if at < 0: return 0
  var body = spanReader(r, s.added[at])
  let v = readVarInt(body)
  if ok(body): v else: 0

proc enchantmentCount*(r: Reader; s: SlotItem): int =
  let at = componentSpan(s, "minecraft:enchantments")
  if at < 0: return 0
  var body = spanReader(r, s.added[at])
  let v = readVarInt(body)
  if ok(body) and v >= 0: v else: 0

proc enchantmentAt*(r: Reader; s: SlotItem; index: int;
                    id, level: var int): bool =
  id = 0
  level = 0
  let at = componentSpan(s, "minecraft:enchantments")
  if at < 0: return false
  var body = spanReader(r, s.added[at])
  let n = readVarInt(body)
  if not ok(body) or index < 0 or index >= n: return false
  var i = 0
  while i < index:
    discard readVarInt(body)
    discard readVarInt(body)
    inc i
  id = readVarInt(body)
  level = readVarInt(body)
  ok(body)

proc customNameOf*(r: Reader; s: SlotItem): string =
  ## The renamed title of a stack, as plain text, or "" when it was never
  ## renamed.
  let at = componentSpan(s, "minecraft:custom_name")
  if at < 0: return ""
  var body = spanReader(r, s.added[at])
  let v = readNbt(body)
  if v.problem.len > 0: return ""
  plain(v)

# ---------------------------------------------------------------------------
# Writing, which exists so that every read can be round-tripped

proc putSlotEmpty*(w: var Writer) =
  putVarInt(w, 0)

proc putSlotSimple*(w: var Writer; itemId, count: int) =
  ## A stack with no components at all, which is what the overwhelming majority
  ## of stacks on a real server are.
  putVarInt(w, count)
  putVarInt(w, itemId)
  putVarInt(w, 0)
  putVarInt(w, 0)
