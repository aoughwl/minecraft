## Containers: the inventory, the chest in front of it, and the one number that
## makes clicking work.
##
## THE STATE ID IS THE WHOLE DESIGN, and a client that ignores it is a client
## that desynchronises on the first fast click. Every container packet the server
## sends carries a `stateId`, and every click the client sends echoes the last
## one it saw. The server compares: if they match it trusts the clients picture
## of the container and applies the click; if they do not, it answers with a full
## `container_set_content` and the click is discarded. That is how a click made
## before an update arrived is resolved without either side locking. So
## `Containers` below keeps the last state id per window and `bodyContainerClick`
## sends it - not because the packet has the field, but because the field is the
## protocol.
##
## WINDOW ZERO IS THE PLAYER INVENTORY and is never opened or closed. It is
## always there and its slots are always numbered the same way: 0 is the crafting
## result, 1..4 the crafting grid, 5..8 armour head to feet, 9..35 the main
## inventory with 27..35 being the hotbar, and 45 the off hand. Nothing on the
## wire says any of that; it is the layout the game has had since 1.9 and the
## constants are here so that a caller does not spell them.
##
## `changedSlots` in a click is **what the client predicts the container will
## look like afterwards**, not what it looked like before. Sending the before
## state is the bug that makes every click appear to do nothing and then snap
## back.

import netwire
import netnbt
import netslot

const
  WindowPlayer* = 0
    ## The player inventory, which has no open and no close.
  WindowCursor* = -1
    ## What the wire calls the carried stack when it names a window at all.

  SlotCraftingResult* = 0
  SlotCraftingFirst* = 1
  SlotArmourHead* = 5
  SlotArmourChest* = 6
  SlotArmourLegs* = 7
  SlotArmourFeet* = 8
  SlotInventoryFirst* = 9
  SlotHotbarFirst* = 36
  SlotOffHand* = 45
  PlayerSlotCount* = 46

  # `container_click` modes. The mode changes what `button` means entirely,
  # which is why they are named.
  ClickPickup* = 0          ## left and right click
  ClickQuickMove* = 1       ## shift-click
  ClickSwap* = 2            ## number keys, and the off-hand key
  ClickClone* = 3           ## middle click, creative only
  ClickThrow* = 4           ## Q, and click outside the window
  ClickQuickCraft* = 5      ## the drag
  ClickPickupAll* = 6       ## double click

  MaxContainerSlots* = 256
    ## A double chest plus the player inventory is 90. This is a bound on a
    ## claimed count, not a description of one.

type
  SetSlotPacket* = object
    window*: int
    stateId*: int
    slot*: int
    item*: SlotItem

  SetContentPacket* = object
    window*: int
    stateId*: int
    items*: seq[SlotItem]
    carried*: SlotItem

  ContainerDataPacket* = object
    ## The furnace burn time, the enchanting table levels, the brewing progress.
    ## Two shorts, and what they mean depends on the window type.
    window*: int
    property*: int
    value*: int

  OpenScreenPacket* = object
    window*: int
    kind*: int
    title*: Nbt

  HeldSlotPacket* = object
    slot*: int

  PlayerInventorySlotPacket* = object
    ## `set_player_inventory`, which changes one slot of window zero without the
    ## window or state id the general form carries.
    slot*: int
    item*: SlotItem

  Containers* = object
    ## The state a client must keep to click correctly.
    openWindow*: int         ## -1 when only the inventory is open
    openKind*: int
    lastStateId*: seq[int]   ## by window id, so a stale window cannot answer
    problem*: string

proc containers*(): Containers =
  Containers(openWindow: -1, openKind: -1, lastStateId: @[], problem: "")

proc noteState*(c: var Containers; window, stateId: int) =
  if window < 0 or window > 255: return
  while c.lastStateId.len <= window: c.lastStateId.add 0
  c.lastStateId[window] = stateId

proc stateOf*(c: Containers; window: int): int =
  if window < 0 or window >= c.lastStateId.len: 0 else: c.lastStateId[window]

# ---------------------------------------------------------------------------
# Reading

proc readSetSlotPacket*(r: var Reader; t: ComponentTable): SetSlotPacket =
  result = SetSlotPacket(window: 0, stateId: 0, slot: 0, item: emptySlot())
  result.window = readVarInt(r)
  result.stateId = readVarInt(r)
  result.slot = readShort(r)
  result.item = readSlot(r, t)

proc readSetContentPacket*(r: var Reader; t: ComponentTable): SetContentPacket =
  result = SetContentPacket(window: 0, stateId: 0, items: @[],
                            carried: emptySlot())
  result.window = readVarInt(r)
  result.stateId = readVarInt(r)
  let n = readVarInt(r)
  if not ok(r): return
  if n < 0 or n > MaxContainerSlots:
    fail(r, "a container claims more slots than any container has")
    return
  var i = 0
  while i < n:
    result.items.add readSlot(r, t)
    if not ok(r): return
    inc i
  # The carried stack is part of this packet and not a separate one. Forgetting
  # it leaves the reader one stack short of the end, which is invisible until
  # something else is read from the same frame.
  result.carried = readSlot(r, t)

proc readContainerDataPacket*(r: var Reader): ContainerDataPacket =
  result = ContainerDataPacket(window: 0, property: 0, value: 0)
  result.window = readVarInt(r)
  result.property = readShort(r)
  result.value = readShort(r)

proc readOpenScreenPacket*(r: var Reader): OpenScreenPacket =
  result = OpenScreenPacket(window: 0, kind: 0, title: emptyNbt())
  result.window = readVarInt(r)
  result.kind = readVarInt(r)
  result.title = readNbt(r)
  if result.title.problem.len > 0: fail(r, result.title.problem)

proc readHeldSlotPacket*(r: var Reader): HeldSlotPacket =
  result = HeldSlotPacket(slot: 0)
  result.slot = readVarInt(r)

proc readPlayerInventorySlotPacket*(r: var Reader;
                                    t: ComponentTable): PlayerInventorySlotPacket =
  result = PlayerInventorySlotPacket(slot: 0, item: emptySlot())
  result.slot = readVarInt(r)
  result.item = readSlot(r, t)

proc onContainerPacket*(c: var Containers; opened: bool; window, kind: int) =
  if opened:
    c.openWindow = window
    c.openKind = kind
  else:
    c.openWindow = -1
    c.openKind = -1

# ---------------------------------------------------------------------------
# Writing
#
# A click carries a *hashed* form of every stack it predicts, not the stack
# itself: the server already knows what the items are and only needs to agree
# about which ones moved, so the client sends an item id, a count and a CRC of
# each component rather than the components. A client that sends no components
# at all - which is what an unmodified stack has - needs only the id and count,
# and that is what `putHashedSlot` writes.

proc putHashedSlot*(w: var Writer; present: bool; itemId, count: int) =
  putBool(w, present)
  if not present: return
  putVarInt(w, itemId)
  putVarInt(w, count)
  putVarInt(w, 0)          # no component hashes
  putVarInt(w, 0)          # and none removed

proc bodyContainerClick*(window, stateId, slot, button, mode: int;
                         changedSlots: seq[int]; changedIds: seq[int];
                         changedCounts: seq[int];
                         cursorPresent: bool; cursorId, cursorCount: int): seq[int] =
  ## `changedSlots` is the clients prediction of the container *after* the
  ## click. The three parallel seqs are one entry each; a caller that has no
  ## prediction sends none, which is legal and makes the server correct it.
  var w = writer()
  putVarInt(w, window)
  putVarInt(w, stateId)
  putShort(w, slot)
  putByte(w, button)
  putVarInt(w, mode)
  var n = changedSlots.len
  if changedIds.len < n: n = changedIds.len
  if changedCounts.len < n: n = changedCounts.len
  putVarInt(w, n)
  var i = 0
  while i < n:
    putShort(w, changedSlots[i])
    putHashedSlot(w, changedIds[i] >= 0, changedIds[i], changedCounts[i])
    inc i
  putHashedSlot(w, cursorPresent, cursorId, cursorCount)
  w.data

proc bodyContainerClose*(window: int): seq[int] =
  var w = writer()
  putVarInt(w, window)
  w.data

proc bodySetCreativeModeSlot*(slot, itemId, count: int): seq[int] =
  ## Creative only, and the server refuses it outright in survival. An item id
  ## below zero means "empty this slot", which is the count-zero stack.
  var w = writer()
  putShort(w, slot)
  if itemId < 0 or count <= 0:
    putSlotEmpty(w)
  else:
    putSlotSimple(w, itemId, count)
  w.data
