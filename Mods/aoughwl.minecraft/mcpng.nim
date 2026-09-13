## PNG, both ways, in the interpreter.
##
## `docs/TEXTURES.md` says a mod must never decode an image, and it is right:
## it measures a 1024x512 PNG at about nine seconds of interpreter time, against
## six milliseconds in the host. That arithmetic is about the *size* of the file
## and nothing else, and a Minecraft block texture is **16x16** - 256 pixels,
## about four hundred compressed bytes. Six of them, which is the most faces a
## block has, is under a hundredth of what the rule was written about.
##
## Decoding them is worth that, because it is the only way to get more than one
## picture onto a block. The host's mesh builder has one material per mesh and
## no submeshes, so a furnace, a grass block or a log - anything whose sides do
## not match its top - either wears one face's texture on all six, which is what
## the previous importer did, or arrives as a single picture with all its faces
## in it. `mcatlas.nim` builds that picture and this file is what lets it: read
## the tiles, write the sheet, hand it over as a `data:` URI, which the host
## already decodes (`ModAssetLoader.Fetch`). Nothing bigger than a block texture
## should ever be put through here.
##
## Malformed input answers with `problem` set and an empty image. There is no
## input - truncated, lying about its own sizes, cyclic in its Huffman tables -
## that makes anything here read outside its own buffers or fail to return.

const
  MaxPixels* = 1 shl 20
    ## A megapixel. A block texture is 256 pixels and an animated strip a few
    ## thousand; anything past this is a file that should have gone to the host,
    ## and refusing it is how a resource pack full of 4K art fails politely
    ## instead of hanging the session.

type
  Image* = object
    width*, height*: int
    rgba*: seq[int]     ## width*height*4, 0..255, straight alpha
    problem*: string

proc emptyImage*(): Image =
  Image(width: 0, height: 0, rgba: @[], problem: "")

proc pixels*(img: Image): int = img.width * img.height

# ---------------------------------------------------------------------------
# Inflate (RFC 1951), the "puff" shape: canonical Huffman decoded by walking
# code lengths, so a table is two small seqs and building one cannot overrun.

type
  Bits = object
    data: seq[int]
    at: int          ## byte index
    bit: int         ## 0..7 within that byte
    done: bool       ## ran off the end; every later read answers 0

  Huff = object
    count: seq[int]  ## how many codes of each length, 0..15
    symbol: seq[int] ## symbols ordered by code

proc nextBit(b: var Bits): int =
  if b.at >= b.data.len:
    b.done = true
    return 0
  result = (b.data[b.at] shr b.bit) and 1
  inc b.bit
  if b.bit == 8:
    b.bit = 0
    inc b.at

proc nextBits(b: var Bits; n: int): int =
  var value = 0
  var i = 0
  while i < n:
    value = value or (nextBit(b) shl i)
    inc i
  value

proc align(b: var Bits) =
  if b.bit != 0:
    b.bit = 0
    inc b.at

proc build(lengths: seq[int]; from0, count: int): Huff =
  result = Huff(count: @[], symbol: @[])
  var i = 0
  while i <= 15:
    result.count.add 0
    inc i
  i = 0
  while i < count:
    let l = lengths[from0 + i]
    if l > 0 and l <= 15: result.count[l] = result.count[l] + 1
    inc i
  var offs: seq[int] = @[]
  i = 0
  while i <= 15:
    offs.add 0
    inc i
  var total = 0
  var l = 1
  while l <= 15:
    offs[l] = total
    total = total + result.count[l]
    inc l
  i = 0
  while i < total:
    result.symbol.add 0
    inc i
  i = 0
  while i < count:
    let len0 = lengths[from0 + i]
    if len0 > 0 and len0 <= 15:
      result.symbol[offs[len0]] = i
      offs[len0] = offs[len0] + 1
    inc i

proc decodeSym(b: var Bits; h: Huff): int =
  var code = 0
  var first = 0
  var index = 0
  var l = 1
  while l <= 15:
    code = code or nextBit(b)
    let count = h.count[l]
    if code - first < count:
      if index + (code - first) >= h.symbol.len: return -1
      return h.symbol[index + (code - first)]
    index = index + count
    first = (first + count) shl 1
    code = code shl 1
    inc l
  -1

const
  LenBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43,
             51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  LenExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4,
              4, 4, 5, 5, 5, 5, 0]
  DistBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257,
              385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289,
              16385, 24577]
  DistExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9,
               9, 10, 10, 11, 11, 12, 12, 13, 13]
  ClOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

proc fixedTables(lit, dist: var Huff) =
  var l: seq[int] = @[]
  var i = 0
  while i < 288:
    if i < 144: l.add 8
    elif i < 256: l.add 9
    elif i < 280: l.add 7
    else: l.add 8
    inc i
  lit = build(l, 0, 288)
  var d: seq[int] = @[]
  i = 0
  while i < 30:
    d.add 5
    inc i
  dist = build(d, 0, 30)

proc dynamicTables(b: var Bits; lit, dist: var Huff; problem: var string): bool =
  let hlit = nextBits(b, 5) + 257
  let hdist = nextBits(b, 5) + 1
  let hclen = nextBits(b, 4) + 4
  if hlit > 286 or hdist > 30:
    problem = "a deflate block claims more Huffman codes than there are"
    return false
  var clen: seq[int] = @[]
  var i = 0
  while i < 19:
    clen.add 0
    inc i
  i = 0
  while i < hclen:
    clen[ClOrder[i]] = nextBits(b, 3)
    inc i
  let cl = build(clen, 0, 19)
  var lengths: seq[int] = @[]
  while lengths.len < hlit + hdist:
    let sym = decodeSym(b, cl)
    if sym < 0 or b.done:
      problem = "the compressed data ends inside its own code lengths"
      return false
    if sym < 16:
      lengths.add sym
    elif sym == 16:
      if lengths.len == 0:
        problem = "a code length repeats one that is not there"
        return false
      let prev = lengths[lengths.len - 1]
      var n = 3 + nextBits(b, 2)
      while n > 0 and lengths.len < hlit + hdist:
        lengths.add prev
        dec n
    elif sym == 17:
      var n = 3 + nextBits(b, 3)
      while n > 0 and lengths.len < hlit + hdist:
        lengths.add 0
        dec n
    else:
      var n = 11 + nextBits(b, 7)
      while n > 0 and lengths.len < hlit + hdist:
        lengths.add 0
        dec n
  lit = build(lengths, 0, hlit)
  dist = build(lengths, hlit, hdist)
  true

## Raw deflate. `limit` is what the caller knows the answer must be at most,
## which is what stops a hostile or corrupt stream from allocating forever.
proc inflate*(data: seq[int]; from0, limit: int; problem: var string): seq[int] =
  result = @[]
  var b = Bits(data: data, at: from0, bit: 0, done: false)
  var final = false
  while not final:
    if b.done:
      problem = "the compressed data ends before its last block"
      return result
    final = nextBit(b) == 1
    let kind = nextBits(b, 2)
    if kind == 0:
      align(b)
      if b.at + 4 > b.data.len:
        problem = "a stored block has no length"
        return result
      let n = b.data[b.at] or (b.data[b.at + 1] shl 8)
      let m = b.data[b.at + 2] or (b.data[b.at + 3] shl 8)
      b.at = b.at + 4
      if (n xor 0xFFFF) != m:
        problem = "a stored block's length disagrees with its own check"
        return result
      if b.at + n > b.data.len:
        problem = "a stored block runs past the end of the file"
        return result
      var i = 0
      while i < n:
        if result.len >= limit:
          problem = "the picture is bigger than it said it would be"
          return result
        result.add b.data[b.at + i]
        inc i
      b.at = b.at + n
    elif kind == 1 or kind == 2:
      var lit = Huff(count: @[], symbol: @[])
      var dist = Huff(count: @[], symbol: @[])
      if kind == 1:
        fixedTables(lit, dist)
      else:
        if not dynamicTables(b, lit, dist, problem): return result
      while true:
        let sym = decodeSym(b, lit)
        if sym < 0 or b.done:
          problem = "the compressed data ends inside a block"
          return result
        if sym == 256: break
        if sym < 256:
          if result.len >= limit:
            problem = "the picture is bigger than it said it would be"
            return result
          result.add sym
          continue
        let li = sym - 257
        if li >= 29:
          problem = "a length code that deflate does not have"
          return result
        let length = LenBase[li] + nextBits(b, LenExtra[li])
        let ds = decodeSym(b, dist)
        if ds < 0 or ds >= 30:
          problem = "a distance code that deflate does not have"
          return result
        let back = DistBase[ds] + nextBits(b, DistExtra[ds])
        if back > result.len:
          problem = "a back-reference points before the start of the picture"
          return result
        var i = 0
        while i < length:
          if result.len >= limit:
            problem = "the picture is bigger than it said it would be"
            return result
          # Read out before it is written back: a back-reference into the very
          # bytes being appended is what deflate is *for*, and the one thing the
          # compiler will not let a seq do to itself in one expression.
          let earlier = result[result.len - back]
          result.add earlier
          inc i
    else:
      problem = "a deflate block of a kind that does not exist"
      return result
  result

## zlib (RFC 1950): the two-byte header, then deflate. The Adler check at the
## end is not verified - a truncated stream is caught by inflate itself, and a
## block texture that decoded to the right number of bytes is not going to be
## quietly wrong in a way a checksum would find.
proc zlibInflate*(data: seq[int]; from0, limit: int; problem: var string): seq[int] =
  if from0 + 2 > data.len:
    problem = "there is no compressed data here at all"
    return @[]
  let cmf = data[from0]
  let flg = data[from0 + 1]
  if (cmf and 0x0F) != 8:
    problem = "the picture is compressed with something that is not deflate"
    return @[]
  if ((cmf shl 8) + flg) mod 31 != 0:
    problem = "the compressed data's header fails its own check"
    return @[]
  if (flg and 0x20) != 0:
    problem = "the compressed data wants a preset dictionary"
    return @[]
  inflate(data, from0 + 2, limit, problem)

# ---------------------------------------------------------------------------
# Decode

proc be32(d: seq[int]; at: int): int =
  (d[at] shl 24) or (d[at + 1] shl 16) or (d[at + 2] shl 8) or d[at + 3]

proc paeth(a, b, c: int): int =
  let p = a + b - c
  var pa = p - a
  if pa < 0: pa = -pa
  var pb = p - b
  if pb < 0: pb = -pb
  var pc = p - c
  if pc < 0: pc = -pc
  if pa <= pb and pa <= pc: a
  elif pb <= pc: b
  else: c

proc sampleOf(row: seq[int]; bitAt, depth: int): int =
  ## One sample out of a scanline whose samples are narrower than a byte, and
  ## widened to 0..255 the way the specification says - by replicating, so 1-bit
  ## white is 255 and not 1.
  case depth
  of 1:
    let v = (row[bitAt shr 3] shr (7 - (bitAt and 7))) and 1
    v * 255
  of 2:
    let v = (row[bitAt shr 3] shr (6 - (bitAt and 7))) and 3
    v * 85
  of 4:
    let v = (row[bitAt shr 3] shr (4 - (bitAt and 7))) and 15
    v * 17
  else:
    row[bitAt shr 3]

## Read a PNG into straight RGBA. Colour types 0, 2, 3, 4 and 6 at bit depths 1
## to 16; interlaced files are refused rather than half-read, because Adam7 is
## the one thing in PNG that a texture never is and a wrong guess at it would
## look like a working import.
proc decodePng*(data: seq[int]): Image =
  result = emptyImage()
  if data.len < 8:
    result.problem = "this is not a PNG; it is only " & $data.len & " bytes"
    return result
  const Magic = [137, 80, 78, 71, 13, 10, 26, 10]
  var i = 0
  while i < 8:
    if data[i] != Magic[i]:
      result.problem = "this is not a PNG; its first eight bytes are wrong"
      return result
    inc i
  var width = 0
  var height = 0
  var depth = 0
  var colour = 0
  var interlace = 0
  var palette: seq[int] = @[]
  var alphas: seq[int] = @[]
  var idat: seq[int] = @[]
  var sawHeader = false
  var at = 8
  while at + 8 <= data.len:
    let length = be32(data, at)
    if length < 0 or at + 12 + length > data.len:
      result.problem = "a chunk says it is longer than the rest of the file"
      return result
    var name = ""
    var k = 0
    while k < 4:
      name.add char(data[at + 4 + k])
      inc k
    let body = at + 8
    if name == "IHDR":
      if length < 13:
        result.problem = "the header chunk is too short"
        return result
      width = be32(data, body)
      height = be32(data, body + 4)
      depth = data[body + 8]
      colour = data[body + 9]
      interlace = data[body + 12]
      sawHeader = true
      if width <= 0 or height <= 0:
        result.problem = "the picture says it is " & $width & " by " & $height
        return result
      if width * height > MaxPixels:
        result.problem = "the picture is " & $width & "x" & $height &
          "; a mod may only decode small ones, and this belongs to the host"
        return result
      if interlace != 0:
        result.problem = "this PNG is interlaced, which this does not read"
        return result
    elif name == "PLTE":
      var j = 0
      while j < length:
        palette.add data[body + j]
        inc j
    elif name == "tRNS":
      var j = 0
      while j < length:
        alphas.add data[body + j]
        inc j
    elif name == "IDAT":
      var j = 0
      while j < length:
        idat.add data[body + j]
        inc j
    elif name == "IEND":
      break
    at = body + length + 4
  if not sawHeader:
    result.problem = "this PNG has no header chunk"
    return result
  if idat.len == 0:
    result.problem = "this PNG has no pixels in it"
    return result
  var channels = 0
  case colour
  of 0: channels = 1
  of 2: channels = 3
  of 3: channels = 1
  of 4: channels = 2
  of 6: channels = 4
  else:
    result.problem = "colour type " & $colour & " is not a PNG colour type"
    return result
  if depth != 1 and depth != 2 and depth != 4 and depth != 8 and depth != 16:
    result.problem = "bit depth " & $depth & " is not a PNG bit depth"
    return result
  if colour == 3 and depth == 16:
    result.problem = "a palette cannot have sixteen-bit entries"
    return result
  if colour != 3 and colour != 0 and depth < 8:
    # Greyscale and palette may be narrower than a byte; the three colour types
    # that carry separate channels may not. Vanilla ships at least one 1-bit
    # greyscale block texture - `block/lightning_rod_on` - so refusing this
    # combination is not a theoretical gap, it is a missing block.
    result.problem = "colour type " & $colour & " cannot have " & $depth & "-bit samples"
    return result
  let bitsPerPixel = channels * depth
  let rowBytes = (width * bitsPerPixel + 7) div 8
  let step = (bitsPerPixel + 7) div 8   ## bytes between a pixel and the one left of it
  var problem = ""
  let raw = zlibInflate(idat, 0, (rowBytes + 1) * height, problem)
  if problem.len > 0:
    result.problem = problem
    return result
  if raw.len < (rowBytes + 1) * height:
    result.problem = "this PNG holds " & $raw.len & " bytes where its own size needs " &
      $((rowBytes + 1) * height)
    return result
  var prior: seq[int] = @[]
  var i2 = 0
  while i2 < rowBytes:
    prior.add 0
    inc i2
  result.width = width
  result.height = height
  var y = 0
  while y < height:
    let filter = raw[y * (rowBytes + 1)]
    var row: seq[int] = @[]
    var x = 0
    while x < rowBytes:
      row.add raw[y * (rowBytes + 1) + 1 + x]
      inc x
    x = 0
    while x < rowBytes:
      let a = if x >= step: row[x - step] else: 0
      let b = prior[x]
      let c = if x >= step: prior[x - step] else: 0
      var v = row[x]
      case filter
      of 0: discard
      of 1: v = (v + a) and 255
      of 2: v = (v + b) and 255
      of 3: v = (v + ((a + b) div 2)) and 255
      of 4: v = (v + paeth(a, b, c)) and 255
      else:
        result.problem = "scanline " & $y & " uses filter " & $filter &
          ", and there are only five"
        result.rgba = @[]
        return result
      row[x] = v
      inc x
    x = 0
    while x < width:
      var r = 0
      var g = 0
      var bl = 0
      var al = 255
      if depth == 16:
        let base = x * channels * 2
        if colour == 0:
          r = row[base]; g = r; bl = r
        elif colour == 2:
          r = row[base]; g = row[base + 2]; bl = row[base + 4]
        elif colour == 4:
          r = row[base]; g = r; bl = r; al = row[base + 2]
        else:
          r = row[base]; g = row[base + 2]; bl = row[base + 4]; al = row[base + 6]
      elif colour == 3:
        let index = sampleOf(row, x * depth, depth) div
          (if depth == 1: 255 elif depth == 2: 85 elif depth == 4: 17 else: 1)
        if index * 3 + 2 < palette.len:
          r = palette[index * 3]
          g = palette[index * 3 + 1]
          bl = palette[index * 3 + 2]
        if index < alphas.len: al = alphas[index]
      elif colour == 0 and depth < 8:
        r = sampleOf(row, x * depth, depth)
        g = r
        bl = r
      else:
        let base = x * channels
        if colour == 0:
          r = row[base]; g = r; bl = r
        elif colour == 2:
          r = row[base]; g = row[base + 1]; bl = row[base + 2]
        elif colour == 4:
          r = row[base]; g = r; bl = r; al = row[base + 1]
        else:
          r = row[base]; g = row[base + 1]; bl = row[base + 2]; al = row[base + 3]
      result.rgba.add r
      result.rgba.add g
      result.rgba.add bl
      result.rgba.add al
      inc x
    prior = row
    inc y

# ---------------------------------------------------------------------------
# Encode
#
# Written back out as stored deflate blocks: no compression at all, one CRC and
# one Adler, and every byte of the work is a copy. An atlas of six 16x16 tiles
# with a pixel of padding round each is 108x18, under eight kilobytes - so the
# only thing compression would buy is a shorter `data:` URI, at the cost of a
# Huffman coder in the interpreter. It is not worth it, and this is the reason
# rather than an oversight.

var crcTable: seq[int] = @[]

proc buildCrcTable() =
  if crcTable.len == 256: return
  crcTable = @[]
  var n = 0
  while n < 256:
    var c = n
    var k = 0
    while k < 8:
      if (c and 1) != 0: c = 0xEDB88320 xor (c shr 1)
      else: c = c shr 1
      inc k
    crcTable.add c
    inc n

proc crc32(data: seq[int]; from0, length: int): int =
  buildCrcTable()
  var c = 0xFFFFFFFF
  var i = 0
  while i < length:
    c = crcTable[(c xor data[from0 + i]) and 255] xor (c shr 8)
    inc i
  c xor 0xFFFFFFFF

proc adler32(data: seq[int]): int =
  var a = 1
  var b = 0
  var i = 0
  while i < data.len:
    a = (a + data[i]) mod 65521
    b = (b + a) mod 65521
    inc i
  (b shl 16) or a

proc put32(out0: var seq[int]; v: int) =
  out0.add (v shr 24) and 255
  out0.add (v shr 16) and 255
  out0.add (v shr 8) and 255
  out0.add v and 255

proc chunk(out0: var seq[int]; name: string; body: seq[int]) =
  put32(out0, body.len)
  var framed: seq[int] = @[]
  var i = 0
  while i < name.len:
    framed.add int(name[i])
    inc i
  i = 0
  while i < body.len:
    framed.add body[i]
    inc i
  i = 0
  while i < framed.len:
    out0.add framed[i]
    inc i
  put32(out0, crc32(framed, 0, framed.len))

## An RGBA image as the bytes of a PNG file.
proc encodePng*(img: Image): seq[int] =
  result = @[]
  if img.width <= 0 or img.height <= 0: return result
  const Magic = [137, 80, 78, 71, 13, 10, 26, 10]
  var i = 0
  while i < 8:
    result.add Magic[i]
    inc i
  var header: seq[int] = @[]
  put32(header, img.width)
  put32(header, img.height)
  header.add 8    # bit depth
  header.add 6    # RGBA
  header.add 0    # deflate
  header.add 0    # adaptive filtering
  header.add 0    # no interlace
  chunk(result, "IHDR", header)
  var raw: seq[int] = @[]
  var y = 0
  while y < img.height:
    raw.add 0     # filter: none
    var x = 0
    while x < img.width * 4:
      raw.add img.rgba[(y * img.width * 4) + x]
      inc x
    inc y
  var z: seq[int] = @[]
  z.add 0x78
  z.add 0x01
  var at = 0
  while true:
    var n = raw.len - at
    if n > 65535: n = 65535
    let last = if at + n >= raw.len: 1 else: 0
    z.add last
    z.add n and 255
    z.add (n shr 8) and 255
    z.add (n xor 0xFFFF) and 255
    z.add ((n xor 0xFFFF) shr 8) and 255
    var k = 0
    while k < n:
      z.add raw[at + k]
      inc k
    at = at + n
    if last == 1: break
  put32(z, adler32(raw))
  chunk(result, "IDAT", z)
  var nothing: seq[int] = @[]
  chunk(result, "IEND", nothing)

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

## Bytes as base64, for the `data:` URI the host reads pictures out of.
proc base64*(data: seq[int]): string =
  result = ""
  var i = 0
  while i + 2 < data.len:
    let v = (data[i] shl 16) or (data[i + 1] shl 8) or data[i + 2]
    result.add B64[(v shr 18) and 63]
    result.add B64[(v shr 12) and 63]
    result.add B64[(v shr 6) and 63]
    result.add B64[v and 63]
    i = i + 3
  let left = data.len - i
  if left == 1:
    let v = data[i] shl 16
    result.add B64[(v shr 18) and 63]
    result.add B64[(v shr 12) and 63]
    result.add '='
    result.add '='
  elif left == 2:
    let v = (data[i] shl 16) or (data[i + 1] shl 8)
    result.add B64[(v shr 18) and 63]
    result.add B64[(v shr 12) and 63]
    result.add B64[(v shr 6) and 63]
    result.add '='

## What `useTexture` takes.
proc dataUri*(png: seq[int]): string =
  "data:image/png;base64," & base64(png)
