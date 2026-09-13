## Chunk sections: palette-indexed, bit-packed, and the reason this whole
## direction lives or dies.
##
## A chunk column arrives as a byte array of sections. Each section is a
## 16x16x16 cube of block states and a 4x4x4 grid of biomes, and each of those
## is a *paletted container*: a bits-per-entry byte, a palette, and an array of
## 64-bit longs with the entries packed into them, low bits first, **never
## straddling a long** (that has been true since 1.16 - a decoder written from a
## 1.13 page reads garbage from the second long onward).
##
##   bits == 0            one value for the whole container, no data array
##   blocks, bits 1..8    indirect: the entries index a palette
##   blocks, bits > 8     direct: the entries *are* registry block state ids
##   biomes, bits 1..3    indirect
##   biomes, bits > 3     direct
##
## The server never sends 1..3 for blocks - it raises them to 4 - but the reader
## accepts them, because refusing a legal-looking container that a modded server
## may send costs more than reading it.
##
## **AT PROTOCOL 774 THERE IS NO LENGTH PREFIX, AND THAT IS MEASURED.** This
## file was written to accept either shape because the prefix has been on its
## way out for several versions and guessing would be expensive. The recorded
## join in `Tests/mcplay_test.nim` settles it: 318 real chunk columns from
## Mojang own client and server decode with `expectArrayLength = false` and
## **zero** of them decode with it true. The test discovers that rather than
## asserting it - it runs the whole replay both ways and reports which one
## worked - so the day a version puts the prefix back, the answer changes by
## itself instead of becoming a wrong constant. `main.nim` still benchmarks with
## the prefix on, because the benchmark builds its own fixtures and the prefix
## costs a VarInt per container either way.
##
## THE LENGTH PREFIX IS CHECKED, NOT TRUSTED. Each data array carries a VarInt
## count of longs, and that count is derivable: `ceil(entries / (64 div bits))`.
## They should agree. Recent versions have moved toward dropping the prefix
## because it is redundant, so `expectArrayLength` says whether to read one, and
## when one is read it is compared with the derived count and disagreement is
## refused. A decoder that took the prefix on trust would resynchronise onto the
## wrong byte and produce a plausible, wrong chunk.
##
## WHY THIS FILE AVOIDS PROCS IN ITS INNER LOOP. An interpreted call costs about
## a microsecond; a chunk is 98,304 block entries. One call per block is a tenth
## of a second per chunk before any work is done. So the unpack is written as
## two flat loops over bytes with the palette lookup inline, and the shape of it
## is deliberate rather than untidy. `Tests/mcnet_test.nim` measures what it
## costs, and `main.nim` carries the benchmark that produced the figure.

import netwire

const
  SectionBlocks* = 4096            ## 16 * 16 * 16
  SectionBiomes* = 64              ## 4 * 4 * 4
  MaxBlockIndirectBits* = 8
  MaxBiomeIndirectBits* = 3
  MaxBits* = 31
    ## Anything wider is not a block state id, it is a corrupt stream. 1.21's
    ## direct palette is 15 bits.

type
  Container* = object
    bits*: int                     ## as sent; 0 means single-valued
    single*: int                   ## the value, when bits is 0
    palette*: seq[int]             ## empty when direct or single-valued
    direct*: bool
    values*: seq[int]              ## `entries` decoded values

  Section* = object
    blockCount*: int               ## non-air blocks, as the server counted them
    blocks*: Container
    biomes*: Container

  Column* = object
    x*, z*: int
    sections*: seq[Section]
    problem*: string

proc emptyContainer*(): Container =
  Container(bits: 0, single: 0, palette: @[], direct: false, values: @[])

# ---------------------------------------------------------------------------
# Decode

proc longsFor*(entries, bits: int): int =
  ## The derived count, which is the only count this file believes.
  if bits <= 0: return 0
  let perLong = 64 div bits
  (entries + perLong - 1) div perLong

proc unpack*(data: seq[int]; at, entries, bits: int; palette: seq[int];
             direct: bool; values: var seq[int]; problem: var string): int =
  ## The hot loop. Returns the byte index just past the data array.
  ##
  ## Each long is taken as two non-negative 32-bit halves rather than as one
  ## signed 64-bit word, so that nothing here ever shifts a negative. That is
  ## not caution for its own sake: `shr` on this interpreter's `int` is
  ## arithmetic, so `word shr 60` on a long whose top bit is set smears ones
  ## downward, and the mask afterwards would hide it for narrow entries and not
  ## for wide ones. Two halves have no sign bit to smear.
  result = at
  if bits <= 0 or bits > MaxBits:
    problem = "bits per entry out of range"
    return
  let perLong = 64 div bits
  let longs = (entries + perLong - 1) div perLong
  if at + longs * 8 > data.len:
    problem = "the data array runs past the end of the section"
    return
  let mask = (1 shl bits) - 1
  var p = at
  var produced = 0
  var li = 0
  if direct:
    while li < longs:
      let hi32 = (data[p] shl 24) or (data[p + 1] shl 16) or
                 (data[p + 2] shl 8) or data[p + 3]
      let lo32 = (data[p + 4] shl 24) or (data[p + 5] shl 16) or
                 (data[p + 6] shl 8) or data[p + 7]
      p = p + 8
      var j = 0
      var k = 0
      while k < perLong and produced < entries:
        if j + bits <= 32:
          values[produced] = (lo32 shr j) and mask
        elif j >= 32:
          values[produced] = (hi32 shr (j - 32)) and mask
        else:
          values[produced] = ((lo32 shr j) or (hi32 shl (32 - j))) and mask
        produced = produced + 1
        j = j + bits
        k = k + 1
      li = li + 1
  else:
    let top = palette.len
    while li < longs:
      let hi32 = (data[p] shl 24) or (data[p + 1] shl 16) or
                 (data[p + 2] shl 8) or data[p + 3]
      let lo32 = (data[p + 4] shl 24) or (data[p + 5] shl 16) or
                 (data[p + 6] shl 8) or data[p + 7]
      p = p + 8
      var j = 0
      var k = 0
      while k < perLong and produced < entries:
        var index = 0
        if j + bits <= 32:
          index = (lo32 shr j) and mask
        elif j >= 32:
          index = (hi32 shr (j - 32)) and mask
        else:
          index = ((lo32 shr j) or (hi32 shl (32 - j))) and mask
        if index >= top:
          problem = "an entry indexed past the end of its palette"
          return p
        values[produced] = palette[index]
        produced = produced + 1
        j = j + bits
        k = k + 1
      li = li + 1
  result = p

proc readContainer*(r: var Reader; entries, maxIndirectBits: int;
                    expectArrayLength: bool): Container =
  result = emptyContainer()
  if not ok(r): return
  let bits = readByte(r)
  if not ok(r): return
  result.bits = bits

  if bits == 0:
    result.single = readVarInt(r)
    if expectArrayLength:
      let count = readVarInt(r)
      if ok(r) and count != 0:
        fail(r, "a single-valued container carried a data array")
        return
    return

  if bits > MaxBits:
    fail(r, "bits per entry out of range")
    return

  result.direct = bits > maxIndirectBits
  if not result.direct:
    let size = readVarInt(r)
    if not ok(r): return
    if size <= 0 or size > (1 shl bits):
      fail(r, "palette size out of range for its bits per entry")
      return
    var i = 0
    while i < size:
      result.palette.add readVarInt(r)
      inc i
    if not ok(r): return

  let derived = longsFor(entries, bits)
  if expectArrayLength:
    let sent = readVarInt(r)
    if not ok(r): return
    if sent != derived:
      fail(r, "the data array length disagrees with the one its shape implies")
      return
  if derived * 8 > remaining(r):
    fail(r, "the data array runs past the end")
    return

  result.values = newSeq[int](entries)
  var problem = ""
  let after = unpack(r.data, r.at, entries, bits, result.palette, result.direct,
                     result.values, problem)
  if problem.len > 0:
    fail(r, problem)
    return
  r.at = after

proc readSection*(r: var Reader; expectArrayLength: bool): Section =
  result = Section(blockCount: 0, blocks: emptyContainer(),
                   biomes: emptyContainer())
  result.blockCount = readShort(r)
  result.blocks = readContainer(r, SectionBlocks, MaxBlockIndirectBits,
                                expectArrayLength)
  result.biomes = readContainer(r, SectionBiomes, MaxBiomeIndirectBits,
                                expectArrayLength)

proc readSections*(data: seq[int]; sectionCount: int;
                   expectArrayLength: bool): Column =
  ## The `Data` field of `Chunk Data and Update Light`, which is exactly
  ## `sectionCount` sections back to back and nothing else. The count is not in
  ## the packet: it is the world's height divided by sixteen, which the client
  ## learns from the dimension the server put it in. For the overworld at 774
  ## that is 24 - y from -64 to 320.
  result = Column(x: 0, z: 0, sections: @[], problem: "")
  var r = reader(data)
  var i = 0
  while i < sectionCount:
    let s = readSection(r, expectArrayLength)
    if not ok(r):
      result.problem = r.problem
      return
    result.sections.add s
    inc i
  if remaining(r) != 0:
    # A section decoder that stopped one byte early would still have produced
    # `sectionCount` plausible sections. This is the check that catches it.
    result.problem = "there were bytes left over after the last section"

proc blockAt*(s: Section; x, y, z: int): int =
  ## Block state id at a section-local coordinate. The index order is
  ## `y * 256 + z * 16 + x`, which is the order the packing itself uses.
  if s.blocks.bits == 0: return s.blocks.single
  if s.blocks.values.len != SectionBlocks: return 0
  s.blocks.values[(y shl 8) or (z shl 4) or x]

proc biomeAt*(s: Section; x, y, z: int): int =
  if s.biomes.bits == 0: return s.biomes.single
  if s.biomes.values.len != SectionBiomes: return 0
  s.biomes.values[(y shl 4) or (z shl 2) or x]

# ---------------------------------------------------------------------------
# Encode, which exists so that the decoder can be round-tripped against
# hand-built fixtures with no server anywhere.

proc packInto*(w: var Writer; values: seq[int]; bits: int) =
  let perLong = 64 div bits
  let longs = (values.len + perLong - 1) div perLong
  var at = 0
  var li = 0
  while li < longs:
    var hi32 = 0
    var lo32 = 0
    var j = 0
    var k = 0
    while k < perLong and at < values.len:
      let v = values[at] and ((1 shl bits) - 1)
      if j + bits <= 32:
        lo32 = lo32 or (v shl j)
      elif j >= 32:
        hi32 = hi32 or (v shl (j - 32))
      else:
        lo32 = lo32 or ((v shl j) and 0xFFFFFFFF)
        hi32 = hi32 or (v shr (32 - j))
      at = at + 1
      j = j + bits
      k = k + 1
    putInt(w, hi32 and 0xFFFFFFFF)
    putInt(w, lo32 and 0xFFFFFFFF)
    li = li + 1

proc writeSingle*(w: var Writer; value: int; withArrayLength: bool) =
  putByte(w, 0)
  putVarInt(w, value)
  if withArrayLength: putVarInt(w, 0)

proc writeIndirect*(w: var Writer; palette: seq[int]; indices: seq[int];
                    bits: int; withArrayLength: bool) =
  putByte(w, bits)
  putVarInt(w, palette.len)
  var i = 0
  while i < palette.len:
    putVarInt(w, palette[i])
    inc i
  if withArrayLength: putVarInt(w, longsFor(indices.len, bits))
  packInto(w, indices, bits)

proc writeDirect*(w: var Writer; values: seq[int]; bits: int;
                  withArrayLength: bool) =
  putByte(w, bits)
  if withArrayLength: putVarInt(w, longsFor(values.len, bits))
  packInto(w, values, bits)
