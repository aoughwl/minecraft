## One mod handing the player something another mod is keeping for them.
##
## ## Why this exists at all
##
## A voxel world knows a block broke. It does not know what an inventory is. A
## survival HUD knows what an inventory is and has no idea a block exists. The
## two have to meet somewhere, and in this engine there is exactly one place two
## mods can meet: a catalog. Entity handles cannot cross - the host rebuilds an
## incoming handle with the *caller's* owner and refuses one that was made by
## somebody else - and `save`/`remember` is keyed per mod, so neither of those
## is a channel. A catalog is: any mod may read one, any mod may add a row to
## one, and the row remembers who put it there.
##
## So this is a queue. A producer appends one row per thing that happened; a
## consumer keeps a cursor and reads the rows that arrived since it last looked.
## Nothing here knows what a block, an item or a hit point is - the verb is a
## word and the two mods either agree about it or they do not.
##
##   handOver("give", "cobblestone", 1)      # in the mod that broke the block
##
##   var seen = 0                            # in the mod that keeps the bag
##   for one in handed(seen):
##     if one.verb == "give": ...
##
## ## The one rule
##
## A mod must not consume a verb it also produces, because the queue is shared
## and a row does not say who it was for. The verbs in this tree today:
##
## | verb | who says it | who listens | what it means |
## | --- | --- | --- | --- |
## | `owns` | the world | the HUD | this mod places and drives the character |
## | `give` | the world | the HUD | put this many of this item in the bag |
## | `spend` | the world | the HUD | take this many of it back out |
## | `fell` | the world | the HUD | the player landed after this many decimetres |
## | `walked` | the world | the HUD | the player walked this many metres |
## | `keeps` | the HUD | the world | there is an inventory here; stop keeping one |
## | `hold` | the HUD | the world | this is what is in the player's hand now |
## | `pointer` | the HUD | the world | a screen took the mouse (`free`), or gave it back (`held`) |
##
## ## What replaces it
##
## A host call that lets one mod call a proc in another - the service host - is
## being added. When it lands, `handOver` becomes that call and `handed`
## becomes the proc on the other side; the two call sites in
## `aoughwl.voxel` and `aoughwl.hud` are one line each on purpose.
## Until then this is what there is, and it has the shape of the thing that
## replaces it rather than the shape of a private side channel.
##
## The cost, said out loud: the queue only grows. One row per pickup, per
## placement, per landing, per four metres walked. A catalog row is small and a
## session is not infinite, but this is a queue with no drain and that is a
## thing to fix in the host rather than to hide here.

import jester
import catalogs

const
  HandoffKind* = "aoughwl.handoff"
    ## The kind. Text, because the row is a sentence three mods have to agree
    ## about rather than a number one of them owns.
  HandoffCatalog* = "aoughwl.player.handoff"
    ## The queue itself.

type Handoff* = object
  ## One row, read apart. `verb` is what happened, `subject` is what it happened
  ## to - an item id, or empty when the verb needs no noun - and `amount` is how
  ## much, which is always a whole number so the row never has to carry a
  ## decimal point across two parsers.
  verb*: string
  subject*: string
  amount*: int
  from0*: string
    ## Which mod said it. Spelled `from0` because `from` is a keyword.

var posted = 0
  ## How many rows *this mod* has put in. A module-level var has one instance
  ## per mod that imports the module, which is exactly right here: the row id
  ## only has to be unique within one mod's rows, because the host keys a row
  ## on the pair (id, owner) and refuses a repeat of that pair.

## Declare the kind and create the queue, unless somebody already did. The same
## ask-rather-than-assume shape `ensureCatalog` and `declareGridKinds` use: a
## catalog that exists has a signature and one that does not is the empty
## string, so whichever mod gets here first owns it and every mod after it just
## adds rows. Load order therefore does not matter, which is the whole point -
## the world mod and the HUD mod each have to be able to speak first.
proc ensureHandoff*() =
  if catalogSignature(HandoffCatalog).len > 0: return
  defineCatalogKind(HandoffKind, "text",
    "One thing a mod handed the player: a verb, a subject and an amount.")
  createCatalog(HandoffCatalog, HandoffKind,
    "Everything mods have handed the player, in the order it happened.")

## Say that something happened to the player. This is the producer's whole
## surface, and it is one line at the call site by design.
proc handOver*(verb, subject: string; amount = 1) =
  ensureHandoff()
  posted = posted + 1
  addToCatalog(HandoffCatalog, "h" & $posted,
    verb & "|" & subject & "|" & $amount)

## How many rows are in the queue - zero when nobody has made it yet, because
## the host answers zero for a catalog that does not exist rather than raising.
proc handoffCount*(): int = catalogCount(HandoffCatalog)

proc wholeOf(text: string; fallback: int): int =
  if text.len == 0: return fallback
  var i = 0
  var sign = 1
  if text[0] == '-':
    sign = -1
    i = 1
  var value = 0
  var digits = 0
  while i < text.len:
    if text[i] < '0' or text[i] > '9': return fallback
    value = value * 10 + (ord(text[i]) - ord('0'))
    digits = digits + 1
    i = i + 1
  if digits == 0: return fallback
  sign * value

## One row, read apart. A row that does not spell a handoff comes back with an
## empty verb rather than raising: the text is another mod's typing.
proc handoffAt*(index: int): Handoff =
  result = Handoff(verb: "", subject: "", amount: 0, from0: "")
  if index < 0 or index >= catalogCount(HandoffCatalog): return result
  let text = catalogText(HandoffCatalog, index)
  var field = 0
  var part = ""
  var verb = ""
  var subject = ""
  var amount = "1"
  var i = 0
  while i <= text.len:
    if i == text.len or text[i] == '|':
      if field == 0: verb = part
      elif field == 1: subject = part
      elif field == 2: amount = part
      part = ""
      field = field + 1
    else:
      part.add text[i]
    i = i + 1
  if field < 2: return result
  result = Handoff(verb: verb, subject: subject,
    amount: wholeOf(amount, 1),
    from0: catalogItemProvider(HandoffCatalog, index))

## Everything that arrived since this consumer last looked, oldest first. The
## cursor is the caller's - one per consumer - and is moved past every row this
## walk yields, so a consumer that stops caring simply stops calling.
iterator handed*(cursor: var int): Handoff {.sideEffect.} =
  let now = catalogCount(HandoffCatalog)
  if cursor < 0: cursor = 0
  while cursor < now:
    let one = handoffAt(cursor)
    cursor = cursor + 1
    if one.verb.len > 0: yield one

## Whether anybody has ever said this verb. The cheap way for a mod to ask "is
## there a world out there / is there a bag out there" without keeping a cursor
## of its own.
proc anybodySaid*(verb: string): bool =
  result = false
  var i = 0
  let now = catalogCount(HandoffCatalog)
  while i < now:
    if handoffAt(i).verb == verb: return true
    i = i + 1
