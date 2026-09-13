## NBT, as a flat arena rather than a tree, and in the *network* dialect.
##
## Two reasons this is its own file. First, NBT is not one of Play's packets, it
## is one of Play's **types**: a text component, a block entity's contents, an
## item's `custom_data` and a dozen registry payloads are all NBT, so a Play
## decoder without an NBT reader cannot even find where a packet ends. Second,
## it is pure arithmetic over bytes exactly like `netwire`, so it is provable
## against hand-built vectors with no server anywhere - which is the whole
## reason the rest of this mod is shaped the way it is.
##
## THE ONE THING THAT CHANGED, AND IT CHANGED RECENTLY. Before 1.20.2 a network
## NBT value was a tag byte, a **name**, and a payload, exactly like a file on
## disk. From 1.20.2 the root name is gone: a network NBT value is a tag byte
## and a payload. `readNbt` reads the 1.20.2+ shape, which is the shape at
## protocol 774, and `readNamedNbt` reads the old one - not because anything
## here sends the old one, but because the difference is two bytes of length
## prefix and a decoder that guessed would read a compound whose first key was
## the old root name and be plausibly, silently wrong. Both are here so the
## difference is visible instead of assumed.
##
## `TAG_End` as the root is how the wire says *absent*, which the protocol calls
## `anonOptionalNbt`: `present` is false and nothing else was read.
##
## WHY AN ARENA. The shape is the one `aoughwl.minecraft/mcjson.nim` uses,
## for the same reason it gives there: a tree of `ref` nodes costs an allocation
## and an indirection per tag, and a text component six tags deep is walked
## every time a chat line is drawn. Parallel `seq`s index in one read.
##
## Nothing here raises. A malformed value sets `problem` and the arena is
## returned as far as it got, which a caller checks - the same contract as
## `netwire.Reader`, and for the same reason: a truncated value must be refused
## rather than silently completed.

import netwire

const
  TagEnd* = 0
  TagByte* = 1
  TagShort* = 2
  TagInt* = 3
  TagLong* = 4
  TagFloat* = 5
  TagDouble* = 6
  TagByteArray* = 7
  TagString* = 8
  TagList* = 9
  TagCompound* = 10
  TagIntArray* = 11
  TagLongArray* = 12

  MaxNesting* = 512
    ## Vanilla network limit is 512 levels of nesting, and a value past it is
    ## refused rather than taken to the interpreter stack.
  MaxElements* = 8388608
    ## A bound on a single claimed array length, so that a lying count cannot
    ## make this allocate before the bytes that would fill it have arrived. The
    ## bytes are checked too; this stops the allocation happening first.

type
  Nbt* = object
    kind*: seq[int]          ## one of the Tag constants
    key*: seq[string]        ## the name this node had inside its compound
    num*: seq[int]           ## byte/short/int/long value
    dec*: seq[float]         ## float/double value
    text*: seq[string]       ## string payload, as bytes
    first*: seq[int]         ## index into `kids` (compound, list) or `pool`
    count*: seq[int]         ## how many
    listKind*: seq[int]      ## element tag of a list; 0 for everything else
    kids*: seq[int]
    pool*: seq[int]          ## byte/int/long array payloads, back to back
    root*: int               ## -1 when the value was absent
    present*: bool
    problem*: string

proc emptyNbt*(): Nbt =
  Nbt(kind: @[], key: @[], num: @[], dec: @[], text: @[], first: @[],
      count: @[], listKind: @[], kids: @[], pool: @[], root: -1,
      present: false, problem: "")

proc failDoc(doc: var Nbt; why: string) =
  if doc.problem.len == 0: doc.problem = why

proc node(doc: var Nbt; kind: int): int =
  doc.kind.add kind
  doc.key.add ""
  doc.num.add 0
  doc.dec.add 0.0
  doc.text.add ""
  doc.first.add 0
  doc.count.add 0
  doc.listKind.add 0
  doc.kind.len - 1

proc tagName*(tag: int): string =
  ## Used in messages, so that a refusal says which tag it choked on rather than
  ## a number the reader would have to look up.
  case tag
  of TagEnd: "end"
  of TagByte: "byte"
  of TagShort: "short"
  of TagInt: "int"
  of TagLong: "long"
  of TagFloat: "float"
  of TagDouble: "double"
  of TagByteArray: "byte array"
  of TagString: "string"
  of TagList: "list"
  of TagCompound: "compound"
  of TagIntArray: "int array"
  of TagLongArray: "long array"
  else: "tag " & $tag

# ---------------------------------------------------------------------------
# Reading
#
# An NBT string is an *unsigned short* byte length and then that many bytes of
# modified UTF-8 - not a VarInt, which is what every other length in this
# protocol is. Reading it as a VarInt is the mistake that makes a compound
# decode for one or two keys and then wander off, so it is spelled out here
# rather than reusing `readString`.

proc readNbtString*(r: var Reader): string =
  result = ""
  if not ok(r): return
  let length = readUShort(r)
  if not ok(r): return
  if length > remaining(r):
    fail(r, "an NBT string runs past the end")
    return
  var i = 0
  while i < length:
    result.add char(r.data[r.at + i])
    inc i
  r.at = r.at + length

proc readPayload(doc: var Nbt; r: var Reader; tag, depth: int): int

proc readCompound(doc: var Nbt; r: var Reader; me, depth: int) =
  ## `me` is already allocated, because the children of a compound are read
  ## before the parent knows where its own run of `kids` starts.
  var children: seq[int] = @[]
  while true:
    if not ok(r): return
    let tag = readByte(r)
    if not ok(r): return
    if tag == TagEnd: break
    let name = readNbtString(r)
    if not ok(r): return
    let child = readPayload(doc, r, tag, depth + 1)
    if doc.problem.len > 0 or not ok(r): return
    doc.key[child] = name
    children.add child
  doc.first[me] = doc.kids.len
  doc.count[me] = children.len
  var i = 0
  while i < children.len:
    doc.kids.add children[i]
    inc i

proc readPayload(doc: var Nbt; r: var Reader; tag, depth: int): int =
  if depth > MaxNesting:
    failDoc(doc, "NBT nested deeper than the protocol allows")
    return 0
  result = node(doc, tag)
  case tag
  of TagByte:
    doc.num[result] = readSByte(r)
  of TagShort:
    doc.num[result] = readShort(r)
  of TagInt:
    doc.num[result] = readInt(r)
  of TagLong:
    doc.num[result] = readLong(r)
  of TagFloat:
    doc.dec[result] = readFloat(r)
  of TagDouble:
    doc.dec[result] = readDouble(r)
  of TagString:
    doc.text[result] = readNbtString(r)
  of TagByteArray:
    let n = readInt(r)
    if not ok(r): return
    if n < 0 or n > MaxElements:
      failDoc(doc, "a byte array length is out of range")
      return
    if n > remaining(r):
      failDoc(doc, "a byte array runs past the end")
      return
    doc.first[result] = doc.pool.len
    doc.count[result] = n
    var i = 0
    while i < n:
      doc.pool.add readSByte(r)
      inc i
  of TagIntArray:
    let n = readInt(r)
    if not ok(r): return
    if n < 0 or n > MaxElements:
      failDoc(doc, "an int array length is out of range")
      return
    if n * 4 > remaining(r):
      failDoc(doc, "an int array runs past the end")
      return
    doc.first[result] = doc.pool.len
    doc.count[result] = n
    var i = 0
    while i < n:
      doc.pool.add readInt(r)
      inc i
  of TagLongArray:
    let n = readInt(r)
    if not ok(r): return
    if n < 0 or n > MaxElements:
      failDoc(doc, "a long array length is out of range")
      return
    if n * 8 > remaining(r):
      failDoc(doc, "a long array runs past the end")
      return
    doc.first[result] = doc.pool.len
    doc.count[result] = n
    var i = 0
    while i < n:
      doc.pool.add readLong(r)
      inc i
  of TagList:
    let elem = readByte(r)
    if not ok(r): return
    let n = readInt(r)
    if not ok(r): return
    doc.listKind[result] = elem
    if n <= 0:
      # A list of zero elements is legal and its element tag is meaningless;
      # vanilla writes TAG_End for it. An empty list with a real element tag is
      # legal too, so neither is refused.
      doc.count[result] = 0
      doc.first[result] = doc.kids.len
      return
    if n > MaxElements:
      failDoc(doc, "a list length is out of range")
      return
    if elem == TagEnd:
      failDoc(doc, "a non-empty list of TAG_End")
      return
    var children: seq[int] = @[]
    var i = 0
    while i < n:
      let child = readPayload(doc, r, elem, depth + 1)
      if doc.problem.len > 0 or not ok(r): return
      children.add child
      inc i
    doc.first[result] = doc.kids.len
    doc.count[result] = children.len
    i = 0
    while i < children.len:
      doc.kids.add children[i]
      inc i
  of TagCompound:
    readCompound(doc, r, result, depth)
  else:
    failDoc(doc, "an NBT tag this reader does not know: " & $tag)

proc readNbt*(r: var Reader): Nbt =
  ## The 1.20.2+ network shape: a tag byte and a payload, no root name.
  ## `TAG_End` means the value was absent, which is the optional form.
  result = emptyNbt()
  if not ok(r): return
  let tag = readByte(r)
  if not ok(r):
    result.problem = "an NBT value ran off the end before its tag"
    return
  if tag == TagEnd:
    result.present = false
    result.root = -1
    return
  result.present = true
  result.root = readPayload(result, r, tag, 0)
  if result.problem.len == 0 and not ok(r):
    result.problem = r.problem
  if result.problem.len > 0:
    # A value that did not finish is not a value. Say so on the reader too, so
    # that a caller which only checks the reader still stops.
    fail(r, result.problem)

proc readNamedNbt*(r: var Reader): Nbt =
  ## The pre-1.20.2 shape, kept so that the difference between the two is a
  ## thing this file states rather than a thing a later reader has to infer.
  ## The root name is read and discarded: nothing on the wire consults it.
  result = emptyNbt()
  if not ok(r): return
  let tag = readByte(r)
  if not ok(r): return
  if tag == TagEnd:
    result.present = false
    return
  discard readNbtString(r)
  if not ok(r): return
  result.present = true
  result.root = readPayload(result, r, tag, 0)
  if result.problem.len > 0: fail(r, result.problem)

# ---------------------------------------------------------------------------
# Walking

proc okNbt*(doc: Nbt): bool = doc.problem.len == 0

proc kindOf*(doc: Nbt; at: int): int =
  if at < 0 or at >= doc.kind.len: TagEnd else: doc.kind[at]

proc childCount*(doc: Nbt; at: int): int =
  if at < 0 or at >= doc.count.len: return 0
  if doc.kind[at] == TagCompound or doc.kind[at] == TagList: doc.count[at]
  else: 0

proc childAt*(doc: Nbt; at, index: int): int =
  ## -1 rather than a wrong node, so that a walk over a value which is not the
  ## shape it was expected to be stops instead of reading a sibling.
  if at < 0 or at >= doc.count.len: return -1
  if doc.kind[at] != TagCompound and doc.kind[at] != TagList: return -1
  if index < 0 or index >= doc.count[at]: return -1
  let slot = doc.first[at] + index
  if slot < 0 or slot >= doc.kids.len: return -1
  doc.kids[slot]

proc childNamed*(doc: Nbt; at: int; name: string): int =
  if at < 0 or at >= doc.count.len: return -1
  if doc.kind[at] != TagCompound: return -1
  var i = 0
  while i < doc.count[at]:
    let c = childAt(doc, at, i)
    if c >= 0 and doc.key[c] == name: return c
    inc i
  result = -1

proc field*(doc: Nbt; name: string): int =
  ## A key of the root compound, which is where nearly every consumer starts.
  childNamed(doc, doc.root, name)

proc wholeAt*(doc: Nbt; at, fallback: int): int =
  if at < 0 or at >= doc.num.len: return fallback
  case doc.kind[at]
  of TagByte, TagShort, TagInt, TagLong: doc.num[at]
  of TagFloat, TagDouble: int(doc.dec[at])
  else: fallback

proc realAt*(doc: Nbt; at: int; fallback: float): float =
  if at < 0 or at >= doc.dec.len: return fallback
  case doc.kind[at]
  of TagFloat, TagDouble: doc.dec[at]
  of TagByte, TagShort, TagInt, TagLong: float(doc.num[at])
  else: fallback

proc textAt*(doc: Nbt; at: int): string =
  if at < 0 or at >= doc.text.len: return ""
  if doc.kind[at] != TagString: return ""
  doc.text[at]

proc arrayLen*(doc: Nbt; at: int): int =
  if at < 0 or at >= doc.count.len: return 0
  let k = doc.kind[at]
  if k != TagByteArray and k != TagIntArray and k != TagLongArray: return 0
  doc.count[at]

proc arrayAt*(doc: Nbt; at, index: int): int =
  ## One element of a byte, int or long array.
  if index < 0 or index >= arrayLen(doc, at): return 0
  doc.pool[doc.first[at] + index]

# ---------------------------------------------------------------------------
# Text components, which are NBT and not JSON since 1.20.3
#
# The full component grammar is large - styles, hover events, translation
# arguments resolved against the client own language files - and none of it is
# needed to know *what a message said*. `plain` is the part that is: the literal
# text, the children under `extra`, and a `translate` key rendered as its own id
# when there is nothing to render it with. A caller that wants styling walks the
# arena itself; a caller that wants a line in a log wants this.

proc plainInto(doc: Nbt; at: int; into: var string; depth: int) =
  if at < 0 or depth > 32: return
  case doc.kind[at]
  of TagString:
    # A bare string *is* a component, which is the shape most servers send for
    # a plain line.
    into.add doc.text[at]
  of TagList:
    var i = 0
    while i < doc.count[at]:
      plainInto(doc, childAt(doc, at, i), into, depth + 1)
      inc i
  of TagCompound:
    let t = childNamed(doc, at, "text")
    if t >= 0: into.add textAt(doc, t)
    else:
      let tr = childNamed(doc, at, "translate")
      if tr >= 0:
        into.add textAt(doc, tr)
        let args = childNamed(doc, at, "with")
        if args >= 0:
          into.add "("
          var i = 0
          while i < doc.count[args]:
            if i > 0: into.add ", "
            plainInto(doc, childAt(doc, args, i), into, depth + 1)
            inc i
          into.add ")"
    let extra = childNamed(doc, at, "extra")
    if extra >= 0:
      var i = 0
      while i < doc.count[extra]:
        plainInto(doc, childAt(doc, extra, i), into, depth + 1)
        inc i
  else:
    discard

proc plain*(doc: Nbt): string =
  ## What a text component says, with its styling dropped.
  result = ""
  if not doc.present: return
  plainInto(doc, doc.root, result, 0)

# ---------------------------------------------------------------------------
# Writing, which exists so that every read can be round-tripped

proc putNbtString*(w: var Writer; s: string) =
  putShort(w, s.len)
  var i = 0
  while i < s.len:
    w.data.add int(s[i]) and 0xFF
    inc i

proc writePayload*(w: var Writer; doc: Nbt; at: int; depth: int = 0) =
  ## The depth bound is not decoration. A malformed arena - one whose `kids` run
  ## contains its own parent - would otherwise make this descend forever, and a
  ## writer that hangs is worse than one that writes a short value. `wellFormed`
  ## is how a caller finds out before writing; this is what happens if it did
  ## not ask.
  if at < 0 or at >= doc.kind.len: return
  if depth > MaxNesting: return
  case doc.kind[at]
  of TagByte: putByte(w, doc.num[at])
  of TagShort: putShort(w, doc.num[at])
  of TagInt: putInt(w, doc.num[at])
  of TagLong: putLong(w, doc.num[at])
  of TagFloat: putFloat(w, doc.dec[at])
  of TagDouble: putDouble(w, doc.dec[at])
  of TagString: putNbtString(w, doc.text[at])
  of TagByteArray:
    putInt(w, doc.count[at])
    var i = 0
    while i < doc.count[at]:
      putByte(w, doc.pool[doc.first[at] + i])
      inc i
  of TagIntArray:
    putInt(w, doc.count[at])
    var i = 0
    while i < doc.count[at]:
      putInt(w, doc.pool[doc.first[at] + i])
      inc i
  of TagLongArray:
    putInt(w, doc.count[at])
    var i = 0
    while i < doc.count[at]:
      putLong(w, doc.pool[doc.first[at] + i])
      inc i
  of TagList:
    var elem = doc.listKind[at]
    if doc.count[at] == 0 and elem == 0: elem = TagEnd
    putByte(w, elem)
    putInt(w, doc.count[at])
    var i = 0
    while i < doc.count[at]:
      writePayload(w, doc, childAt(doc, at, i), depth + 1)
      inc i
  of TagCompound:
    var i = 0
    while i < doc.count[at]:
      let c = childAt(doc, at, i)
      putByte(w, doc.kind[c])
      putNbtString(w, doc.key[c])
      writePayload(w, doc, c, depth + 1)
      inc i
    putByte(w, TagEnd)
  else:
    discard

proc putNbt*(w: var Writer; doc: Nbt) =
  ## The 1.20.2+ shape, and `TAG_End` for an absent value.
  if not doc.present or doc.root < 0:
    putByte(w, TagEnd)
    return
  putByte(w, doc.kind[doc.root])
  writePayload(w, doc, doc.root, 0)

# ---------------------------------------------------------------------------
# Building, so that a test can make a value without parsing one first

proc newCompound*(doc: var Nbt): int =
  ## An empty compound. It has no children until `addChildren` gives it some,
  ## and that call is the only way to give it any - see the warning there.
  result = node(doc, TagCompound)
  doc.first[result] = 0
  doc.count[result] = 0

proc newList*(doc: var Nbt; elem: int): int =
  result = node(doc, TagList)
  doc.listKind[result] = elem
  doc.first[result] = 0
  doc.count[result] = 0

proc newInt*(doc: var Nbt; tag, value: int): int =
  result = node(doc, tag)
  doc.num[result] = value

proc newReal*(doc: var Nbt; tag: int; value: float): int =
  result = node(doc, tag)
  doc.dec[result] = value

proc newText*(doc: var Nbt; value: string): int =
  result = node(doc, TagString)
  doc.text[result] = value

proc newArray*(doc: var Nbt; tag: int; values: seq[int]): int =
  result = node(doc, tag)
  doc.first[result] = doc.pool.len
  doc.count[result] = values.len
  var i = 0
  while i < values.len:
    doc.pool.add values[i]
    inc i

proc addChildren*(doc: var Nbt; parent: int; children: seq[int];
                  names: seq[string]) =
  ## Give `parent` its children, all at once.
  ##
  ## **This is the only correct way to build a branch, and the reason is the
  ## arena.** A parent owns the run `kids[first ..< first+count]`, so its
  ## children must be *consecutive* in `kids`. Adding them one at a time, with
  ## anything else added in between, gives the parent a run that contains
  ## somebody else - and the somebody else can be the parent itself, which is a
  ## cycle that a walk follows forever.
  ##
  ## That is not a hypothetical: the first version of this file offered an
  ## `attach` that appended one child at a time, and the first test written
  ## against it built a list whose single child was the list, and the test
  ## process died of a stack overflow rather than failing. `wellFormed` below is
  ## the check that turns that crash into a red assertion, and it is asserted on
  ## every value this mod builds.
  ##
  ## So: build every child completely, *then* call this once.
  if parent < 0 or parent >= doc.count.len: return
  doc.first[parent] = doc.kids.len
  doc.count[parent] = children.len
  var i = 0
  while i < children.len:
    let c = children[i]
    if c >= 0 and c < doc.key.len:
      if i < names.len: doc.key[c] = names[i]
    doc.kids.add c
    inc i

proc visit(doc: Nbt; at: int; seen: var seq[int]; depth: int): bool =
  if at < 0 or at >= doc.kind.len: return false
  if depth > MaxNesting: return false
  if seen[at] != 0: return false          # reached twice: shared or a cycle
  seen[at] = 1
  if doc.kind[at] == TagCompound or doc.kind[at] == TagList:
    if doc.first[at] < 0: return false
    if doc.first[at] + doc.count[at] > doc.kids.len: return false
    var i = 0
    while i < doc.count[at]:
      if not visit(doc, doc.kids[doc.first[at] + i], seen, depth + 1):
        return false
      inc i
  true

proc wellFormed*(doc: Nbt): bool =
  ## Whether the arena is a tree: every run in range, and no node reached twice.
  ## A value that fails this cannot be walked, written or compared, and the
  ## failure mode of walking it anyway is an infinite descent rather than a
  ## wrong answer - which is why this is a check and not a comment.
  if not doc.present: return doc.root < 0
  if doc.root < 0 or doc.root >= doc.kind.len: return false
  var seen = newSeq[int](doc.kind.len)
  visit(doc, doc.root, seen, 0)

proc setRoot*(doc: var Nbt; at: int) =
  doc.root = at
  doc.present = at >= 0
