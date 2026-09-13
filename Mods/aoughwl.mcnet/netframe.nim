## Packet framing, and the one piece of state that changes what a frame means.
##
## A connection is a byte stream, not a packet stream, so the first job is
## finding where one packet ends. Every packet is a VarInt length then that many
## bytes. After the server sends `Set Compression`, every packet gains a second
## VarInt - the *uncompressed* length - and a zlib payload when that length is
## non-zero, or a plain body when it is zero. That is the whole of it, and it is
## also the whole of why framing is its own file: the threshold is per
## connection, it changes mid-stream, and a decoder that got it wrong would
## still parse *something* out of every packet.
##
## **ON THE LIVE PATH THE HOST DOES THIS, NOT THIS FILE - AND THIS FILE STAYS.**
## The transport seam gives the mod one whole packet at a time: the host owns the
## socket, the length prefix, the compression threshold, the inflate and the
## cipher. So on a real connection nothing below is called, and two framings on
## one path would be worse than either.
##
## It is kept, compiled and tested for a reason that is not sentiment. A recorded
## join is a **byte stream**, not a packet stream - its record boundaries are TCP
## read boundaries, so a packet routinely spans two records and two packets
## routinely share one - and something has to cut it into packets offline.
## `Tests/mcplay_test.nim` replays 5,755 such records through this file and
## decodes 52,119 packets out of them, which makes this both the offline
## replayer and the independent check that the hosts framing agrees with a
## second implementation written from the format rather than from the hosts
## code. `netchunk` is kept for exactly the same reason and says so.
##
## THIS LAYER DOES NOT INFLATE. It hands back the deflated bytes and the length
## they claim to expand to, and lets the caller supply the inflate. That is
## deliberate: `Tests/mcnet_test.nim` measures a pure-interpreter inflate at a
## cost that rules it out on the frame, so the real client will hand this
## payload to a host call. Keeping the seam here means the decision above it can
## change without this file changing.
##
## PARTIAL INPUT IS NOT AN ERROR. A socket hands over whatever arrived, which is
## routinely half a length prefix. `nextFrame` answers `FrameNone` and consumes
## nothing, and the caller feeds more. A frame is only ever refused for
## something that could not become valid with more bytes: a length that is
## negative, a length past the cap, or a claimed uncompressed size below the
## threshold that produced it.

import netwire

const
  MaxPacketBytes* = 2097151
    ## Three VarInt bytes' worth, which is the cap vanilla's own length field
    ## carries. A larger claim is a hostile or desynchronised stream and the
    ## connection is finished either way.
  MaxUncompressedBytes* = 8388608
    ## Eight megabytes. A chunk packet is tens to hundreds of kilobytes; this is
    ## two orders of magnitude of headroom and still a bound.
  NoCompression* = -1

  FrameNone* = 0        ## not enough bytes yet - feed more, consume nothing
  FramePlain* = 1       ## `data` is the packet body, id VarInt first
  FrameDeflated* = 2    ## `data` is zlib, and expands to `uncompressedLen`
  FrameBroken* = 3      ## the stream is not a stream of packets any more

type
  Framing* = object
    threshold*: int      ## `NoCompression`, or the size at or above which the
                         ## server compresses
    buf*: seq[int]
    at*: int             ## how much of `buf` has been consumed
    problem*: string

  Frame* = object
    kind*: int
    data*: seq[int]
    uncompressedLen*: int

proc framing*(): Framing =
  Framing(threshold: NoCompression, buf: @[], at: 0, problem: "")

proc compressing*(f: Framing): bool = f.threshold >= 0

proc setCompression*(f: var Framing; threshold: int) =
  ## What `Set Compression` (login, id 0x03) does. A negative threshold turns it
  ## back off, which is what vanilla means by sending -1.
  f.threshold = threshold

proc feed*(f: var Framing; bytes: seq[int]) =
  var i = 0
  while i < bytes.len:
    f.buf.add bytes[i]
    inc i

proc compact*(f: var Framing) =
  ## Drop what has been consumed. Called after every successful frame, so the
  ## buffer is the size of the packet in flight rather than the size of the
  ## session.
  if f.at == 0: return
  var rest: seq[int] = @[]
  var i = f.at
  while i < f.buf.len:
    rest.add f.buf[i]
    inc i
  f.buf = rest
  f.at = 0

proc pending*(f: Framing): int =
  if f.at >= f.buf.len: 0 else: f.buf.len - f.at

proc peekVarInt(f: Framing; from0: int; value: var int; size: var int): int =
  ## 1 read it, 0 needs more bytes, -1 refused. Deliberately *not* `readVarInt`:
  ## running off the end here is the ordinary case, not a failure.
  value = 0
  size = 0
  var count = 0
  var acc = 0
  var i = from0
  while true:
    if i >= f.buf.len: return 0
    let b = f.buf[i] and 0xFF
    inc i
    acc = acc or ((b and 0x7F) shl (7 * count))
    inc count
    if (b and 0x80) == 0:
      acc = acc and 0xFFFFFFFF
      if (acc and 0x80000000) != 0: acc = acc - 4294967296
      value = acc
      size = count
      return 1
    if count >= MaxVarIntBytes: return -1

proc nextFrame*(f: var Framing): Frame =
  ## One packet, or `FrameNone`. Consumes only on success.
  result = Frame(kind: FrameNone, data: @[], uncompressedLen: 0)
  if f.problem.len > 0:
    result.kind = FrameBroken
    return

  var length = 0
  var lengthSize = 0
  let got = peekVarInt(f, f.at, length, lengthSize)
  if got == 0: return
  if got < 0:
    f.problem = "the length prefix is not a VarInt"
    result.kind = FrameBroken
    return
  if length <= 0 or length > MaxPacketBytes:
    f.problem = "packet length out of range"
    result.kind = FrameBroken
    return

  let bodyAt = f.at + lengthSize
  if f.buf.len - bodyAt < length: return          # the body has not all arrived
  let bodyEnd = bodyAt + length

  if not compressing(f):
    result.kind = FramePlain
    var i = bodyAt
    while i < bodyEnd:
      result.data.add f.buf[i]
      inc i
    f.at = bodyEnd
    compact(f)
    return

  var claimed = 0
  var claimedSize = 0
  let gotClaim = peekVarInt(f, bodyAt, claimed, claimedSize)
  if gotClaim <= 0:
    f.problem = "the uncompressed length is not a VarInt"
    result.kind = FrameBroken
    return
  let payloadAt = bodyAt + claimedSize
  if payloadAt > bodyEnd:
    f.problem = "the uncompressed length overran its own packet"
    result.kind = FrameBroken
    return

  if claimed == 0:
    result.kind = FramePlain
  else:
    if claimed < f.threshold:
      # Vanilla refuses this outright, and it matters: a peer that compresses
      # below the threshold it announced is a peer whose framing we do not
      # actually know, and guessing costs a desynchronised stream later.
      f.problem = "compressed below the announced threshold"
      result.kind = FrameBroken
      return
    if claimed > MaxUncompressedBytes:
      f.problem = "uncompressed length past the cap"
      result.kind = FrameBroken
      return
    result.kind = FrameDeflated
    result.uncompressedLen = claimed

  var i = payloadAt
  while i < bodyEnd:
    result.data.add f.buf[i]
    inc i
  f.at = bodyEnd
  compact(f)

# ---------------------------------------------------------------------------
# The other direction, which is here so that framing can be round-tripped
# without a server.

proc frameOut*(f: Framing; body: seq[int]): seq[int] =
  ## `body` is the packet, id VarInt first. Uncompressed: a length and the body.
  ## Compressing and under the threshold: a length, a zero, and the body.
  ## Compressing and over it, the caller must have deflated already and says so
  ## with `frameDeflatedOut`.
  var inner = writer()
  if compressing(f):
    putVarInt(inner, 0)
  putBytes(inner, body)
  var w = writer()
  putVarInt(w, inner.data.len)
  putBytes(w, inner.data)
  result = w.data

proc frameDeflatedOut*(deflated: seq[int]; uncompressedLen: int): seq[int] =
  var inner = writer()
  putVarInt(inner, uncompressedLen)
  putBytes(inner, deflated)
  var w = writer()
  putVarInt(w, inner.data.len)
  putBytes(w, inner.data)
  result = w.data
