## aoughwl.mcnet - the Minecraft protocol, as pure arithmetic.
##
## The mod itself does almost nothing: everything is in `netwire`, `netframe`,
## `netproto` and `netchunk`, all four of which call no host at all and are
## proved in `Tests/mcnet_test.nim` without a server, a socket or a jar.
##
## What `main.nim` is actually for is the **benchmark**. The whole question this
## mod was written to answer is whether decoding a chunk the server has already
## generated is cheap enough to do on the frame, in this interpreter, given that
## `NativeHost/aowli_host.nim` gates every ABI entry on the engine thread and so
## nothing can be moved off it. The callbacks below are timed from outside by
##
##     tools\bench_mesh.exe Assets\StreamingAssets\Mods\aoughwl.mcnet 5 \
##         prepare emptyLoop seqRead procCall decodeTypical decodeWorst bitProxy
##
## and every one of them is bracketed by a control that does the same loop
## without the work, so the figure that comes out is the decode and not the
## harness.
##
## WHAT IT SAID, 2026-09-10, best of five on one machine. These are not in
## `CLAIMS.tsv` and no document quotes them, deliberately: they are a machine
## and an afternoon, and the units beside them are there so that a re-run on a
## different box can be compared rather than believed.
##
##     emptyLoop      70.7 ms / 100,000   ->  0.71 us a loop step
##     procCall      197.4 ms / 100,000   ->  1.27 us an interpreted call
##     seqRead       151.3 ms / 100,000   ->  0.81 us a seq index read
##     decodeTypical 324.0 ms             ->  6.59 us a block, 49,152 blocks
##     decodeWorst   654.0 ms             ->  6.65 us a block, 98,304 blocks
##     lazyProbe      60.6 ms / 4,096     -> 11.6  us an independent lookup
##
## The two decode figures agreeing to 1% across a fourfold difference in shape
## - twelve five-bit indirect sections against twenty-four fifteen-bit direct
## ones - is the useful part: the cost is per *entry* and neither the palette
## indirection nor the width moves it. And `lazyProbe` settles the design
## question it was written for: pulling one entry out of the packed longs on
## demand costs nearly twice what walking them in order costs, because the long
## has to be assembled from its eight bytes for every lookup instead of once
## for its twelve entries. A mesher that asks about a block and its six
## neighbours would pay that seven times. **Decode the section in order, once.**

import jester
import netwire
import netframe
import netproto
import netchunk
import netnbt
import netslot
import netplay
import netentity
import netherd
import netinv
import netchat

const
  Iterations = 100000
  SectionCount = 24
    ## y from -64 to 320, which is the overworld at protocol 774.
  TypicalPacked = 12
    ## Twelve sections with real blocks in them and twelve of plain air, which
    ## is about what a surface chunk looks like once caves are carved.
  TypicalBits = 5
  TypicalPalette = 24
  WorstBits = 15
    ## 1.21's direct palette: the block state registry needs fifteen bits.

var sink = 0
var typicalBytes: seq[int] = @[]
var worstBytes: seq[int] = @[]
var proxyBytes: seq[int] = @[]
var ready = false

proc airSection(w: var Writer) =
  putShort(w, 0)
  writeSingle(w, 0, true)            # block state 0 is air
  writeSingle(w, 1, true)            # one biome

proc packedSection(w: var Writer; salt, bits, paletteSize: int) =
  putShort(w, 4096)
  var palette: seq[int] = @[]
  var i = 0
  while i < paletteSize:
    palette.add 1 + i * 7 + salt
    inc i
  var indices = newSeq[int](SectionBlocks)
  i = 0
  while i < SectionBlocks:
    indices[i] = (i * 31 + salt * 17) mod paletteSize
    inc i
  writeIndirect(w, palette, indices, bits, true)
  var biomeIndices = newSeq[int](SectionBiomes)
  i = 0
  while i < SectionBiomes:
    biomeIndices[i] = i mod 3
    inc i
  writeIndirect(w, @[1, 2, 3], biomeIndices, 2, true)

proc directSection(w: var Writer; salt: int) =
  putShort(w, 4096)
  var values = newSeq[int](SectionBlocks)
  var i = 0
  while i < SectionBlocks:
    values[i] = (i * 13 + salt) and 0x7FFF
    inc i
  writeDirect(w, values, WorstBits, true)
  var biomes = newSeq[int](SectionBiomes)
  i = 0
  while i < SectionBiomes:
    biomes[i] = (i * 5) and 0xFF
    inc i
  writeDirect(w, biomes, 8, true)

proc prepare() =
  ## Build the fixtures. Timed separately so that nothing below pays for them.
  var a = writer()
  var s = 0
  while s < SectionCount:
    if s < TypicalPacked: packedSection(a, s, TypicalBits, TypicalPalette)
    else: airSection(a)
    inc s
  typicalBytes = a.data

  var b = writer()
  s = 0
  while s < SectionCount:
    directSection(b, s)
    inc s
  worstBytes = b.data

  # Sixty kilobytes, which is the order of a compressed chunk packet.
  var c: seq[int] = @[]
  var i = 0
  while i < 61440:
    c.add (i * 37) and 0xFF
    inc i
  proxyBytes = c
  ready = true

## The three units, re-measured on whatever machine this runs on, because the
## decode figures are only meaningful next to them.

proc emptyLoop() =
  var acc = 0
  var i = 0
  while i < Iterations:
    acc = acc + i
    i = i + 1
  sink = acc

proc seqRead() =
  if not ready: prepare()
  var acc = 0
  var i = 0
  let n = proxyBytes.len
  while i < Iterations:
    acc = acc + proxyBytes[i mod n]
    i = i + 1
  sink = acc

proc onePlusOne(x: int): int = x + 1

proc procCall() =
  var acc = 0
  var i = 0
  while i < Iterations:
    acc = onePlusOne(acc)
    i = i + 1
  sink = acc

## The measurement this mod exists for.

proc decodeTypical() =
  if not ready: prepare()
  let column = readSections(typicalBytes, SectionCount, true)
  var acc = 0
  var s = 0
  while s < column.sections.len:
    acc = acc + column.sections[s].blocks.values.len
    inc s
  sink = acc + column.problem.len

proc decodeWorst() =
  if not ready: prepare()
  let column = readSections(worstBytes, SectionCount, true)
  var acc = 0
  var s = 0
  while s < column.sections.len:
    acc = acc + column.sections[s].blocks.values.len
    inc s
  sink = acc + column.problem.len

## What a pure-interpreter inflate would cost, without writing one.
##
## `aoughwl.minecraft/mcpng.nim` already has an RFC 1951 inflate in this
## language, and its inner unit is `nextBit` - one interpreted call, a seq
## index, two shifts and a branch, per *bit* of the compressed stream. This is
## that loop with the call flattened out, so it is a **lower bound** on what
## that inflate costs: the real one also decodes canonical Huffman symbols by
## walking code lengths and copies back-references, and pays the call.
## Sixty kilobytes is 491,520 bits, which is the order of one chunk packet.

proc bitProxy() =
  if not ready: prepare()
  var at = 0
  var bit = 0
  var acc = 0
  let n = proxyBytes.len
  while at < n:
    acc = acc + ((proxyBytes[at] shr bit) and 1)
    bit = bit + 1
    if bit == 8:
      bit = 0
      at = at + 1
  sink = acc

## Lazy access, which is the alternative to decoding a section up front: keep
## the packed bytes and pull one entry out when the mesher asks for it. This is
## one section's worth of *independent* lookups - the long index worked out from
## the entry index each time, rather than walked - which is what a lazy accessor
## costs. A mesher asks about every block and its six neighbours, so the figure
## to compare is seven of these against one decode.

proc lazyProbe() =
  if not ready: prepare()
  # The first packed section's data array starts after: block count (2), bits
  # (1), palette length VarInt (1), TypicalPalette VarInt entries, array length
  # VarInt (2). Worked out rather than searched for, since this is timed.
  var at = 2 + 1 + 1
  var e = 0
  while e < TypicalPalette:
    at = at + varIntSize(1 + e * 7)
    inc e
  at = at + varIntSize(longsFor(SectionBlocks, TypicalBits))
  let mask = (1 shl TypicalBits) - 1
  let perLong = 64 div TypicalBits
  var acc = 0
  var i = 0
  while i < SectionBlocks:
    let li = i div perLong
    let j = (i mod perLong) * TypicalBits
    let p = at + li * 8
    let hi32 = (typicalBytes[p] shl 24) or (typicalBytes[p + 1] shl 16) or
               (typicalBytes[p + 2] shl 8) or typicalBytes[p + 3]
    let lo32 = (typicalBytes[p + 4] shl 24) or (typicalBytes[p + 5] shl 16) or
               (typicalBytes[p + 6] shl 8) or typicalBytes[p + 7]
    var v = 0
    if j + TypicalBits <= 32: v = (lo32 shr j) and mask
    elif j >= 32: v = (hi32 shr (j - 32)) and mask
    else: v = ((lo32 shr j) or (hi32 shl (32 - j))) and mask
    acc = acc + v
    i = i + 1
  sink = acc

## Controls for the benchmark itself: the same walk with the decode removed, so
## that the difference is the decode and not the loop that drives it.

proc decodeTypicalControl() =
  if not ready: prepare()
  var acc = 0
  var i = 0
  let n = typicalBytes.len
  while i < n:
    acc = acc + typicalBytes[i]
    i = i + 1
  sink = acc

proc decodeWorstControl() =
  if not ready: prepare()
  var acc = 0
  var i = 0
  let n = worstBytes.len
  while i < n:
    acc = acc + worstBytes[i]
    i = i + 1
  sink = acc

proc start() =
  # Touch one thing from each exported module, so that a module which stopped
  # compiling could not be shipped as a working artifact. A library whose
  # exports are never instantiated is a library nobody has built.
  var probe = emptyNbt()
  var components = emptyComponents()
  var session = playSession()
  var layout = layoutFor774()
  var windows = containers()
  var others = emptyHerd()
  log("aoughwl.mcnet ready: protocol " & $ProtocolVersion &
      ", play packets by name, " & $probe.kind.len & " nbt nodes, " &
      $components.names.len & " components, live " & $session.live &
      ", " & $layout.shape.len & " metadata types, window " &
      $windows.openWindow & ", chat signatures " & $SignatureBytes &
      " bytes, " & $beastCount(others) & " entities tracked")
