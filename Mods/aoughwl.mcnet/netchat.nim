## Chat, which is two problems wearing one name.
##
## **Receiving is parsing.** `system_chat` is a text component and a flag;
## `disguised_chat` is three components; `player_chat` is long but every field is
## a shape this mod already reads. All three are implemented below and all three
## are checked.
##
## **Sending a player message is cryptography**, and this file does not do it.
## Since 1.19 a chat message the client sends carries a **256-byte Ed25519-ish
## signature** over the message, a timestamp, a salt and an acknowledged-message
## window, produced with a session key the client fetched from Mojang before it
## connected. Exactly what is required, so that it is a task rather than a
## mystery:
##
##   1. a Mojang session - the online-mode login this client does not do yet -
##      to `POST .../player/certificates` for a 1024-bit RSA private key, a
##      public key and Mojang's signature over that public key with an expiry;
##   2. `chat_session_update`, sent once in Play, carrying a session UUID, the
##      public key, its expiry and Mojang's signature over it;
##   3. per message, an RSA-SHA256 signature over a canonical byte string: a
##      version prefix, the senders UUID, the session UUID, a message index, the
##      salt, the timestamp, the message bytes, and then every acknowledged
##      previous message signature in order;
##   4. the acknowledgement window itself - the last twenty messages seen, as a
##      three-byte bitset and an offset, which `bodyChatAck` below does build,
##      because that part is bookkeeping rather than crypto.
##
## **What works without any of it.** `enforcesSecureChat` in the join packet says
## whether the server insists. When it is false - which is every offline-mode and
## most LAN and modded servers - an *unsigned* message is accepted: the signature
## option is absent and the rest of the packet is as below. `bodyChatUnsigned`
## sends exactly that, and `bodyChatCommand` sends a command, which is never
## signed unless it has signable arguments. So a client can talk and can run
## commands today, and cannot talk on a server that demands signatures - and the
## join packet says in advance which kind of server it is.

import netwire
import netnbt

const
  SignatureBytes* = 256
    ## The fixed width of a chat signature. It carries no length prefix, which
    ## is why it is a constant rather than something read.
  AcknowledgedBytes* = 3
    ## Twenty bits of acknowledged-message window, rounded up to three bytes.
  MaxPreviousMessages* = 20
    ## The window the server keeps. A list longer than this is a lie.

  FilterPassThrough* = 0
  FilterFullyFiltered* = 1
  FilterPartiallyFiltered* = 2

type
  SystemChatPacket* = object
    content*: Nbt
    actionBar*: bool

  DisguisedChatPacket* = object
    ## What the server sends for a message it is relaying on somebody elses
    ## behalf - a command block, a plugin, a player whose message it rewrote -
    ## where there is nothing to verify.
    message*: Nbt
    chatTypeId*: int
    inlineChatType*: bool
    senderName*: Nbt
    hasTarget*: bool
    targetName*: Nbt

  PlayerChatPacket* = object
    globalIndex*: int
    sender*: Uuid
    index*: int
    hasSignature*: bool
    plain*: string           ## what was typed, before any decoration
    timestamp*: int
    salt*: int
    previousCount*: int
    hasUnsigned*: bool
    unsigned*: Nbt           ## the decorated form, when the server rewrote it
    filterType*: int
    chatTypeId*: int
    inlineChatType*: bool
    senderName*: Nbt
    hasTarget*: bool
    targetName*: Nbt

proc readSystemChatPacket*(r: var Reader): SystemChatPacket =
  result = SystemChatPacket(content: emptyNbt(), actionBar: false)
  result.content = readNbt(r)
  if result.content.problem.len > 0:
    fail(r, result.content.problem)
    return
  result.actionBar = readBool(r)

proc readChatTypeHolder(r: var Reader; id: var int; inline0: var bool) =
  ## The chat type is a registry entry holder like every other: `id + 1`, or
  ## zero and then the whole type inline. The inline form carries two decoration
  ## definitions and is refused rather than guessed, because guessing loses the
  ## two components that follow it.
  id = 0
  inline0 = false
  let tag = readVarInt(r)
  if not ok(r): return
  if tag == 0:
    inline0 = true
    fail(r, "an inline chat type definition, which this build does not read")
  else:
    id = tag - 1

proc readDisguisedChatPacket*(r: var Reader): DisguisedChatPacket =
  result = DisguisedChatPacket(message: emptyNbt(), chatTypeId: 0,
                               inlineChatType: false, senderName: emptyNbt(),
                               hasTarget: false, targetName: emptyNbt())
  result.message = readNbt(r)
  if result.message.problem.len > 0:
    fail(r, result.message.problem)
    return
  readChatTypeHolder(r, result.chatTypeId, result.inlineChatType)
  if not ok(r): return
  result.senderName = readNbt(r)
  if result.senderName.problem.len > 0:
    fail(r, result.senderName.problem)
    return
  result.hasTarget = readBool(r)
  if result.hasTarget and ok(r):
    result.targetName = readNbt(r)
    if result.targetName.problem.len > 0: fail(r, result.targetName.problem)

proc readPreviousMessages(r: var Reader; count: var int) =
  ## The acknowledged-message list. Each entry is a VarInt id into the window
  ## the receiver already has, **except** that zero means "not in your window,
  ## here it is" and is followed by a whole 256-byte signature. This shape has no
  ## declared form in the machine-readable 774 profile - it is one of the few
  ## implemented in code - so it is checked against the recorded join instead.
  count = 0
  let n = readVarInt(r)
  if not ok(r): return
  if n < 0 or n > MaxPreviousMessages:
    fail(r, "an acknowledged-message list longer than the window")
    return
  count = n
  var i = 0
  while i < n:
    let id = readVarInt(r)
    if not ok(r): return
    if id == 0:
      if SignatureBytes > remaining(r):
        fail(r, "a previous-message signature runs past the end")
        return
      r.at = r.at + SignatureBytes
    inc i

proc readPlayerChatPacket*(r: var Reader): PlayerChatPacket =
  result = PlayerChatPacket(globalIndex: 0, sender: Uuid(hi: 0, lo: 0),
                            index: 0, hasSignature: false, plain: "",
                            timestamp: 0, salt: 0, previousCount: 0,
                            hasUnsigned: false, unsigned: emptyNbt(),
                            filterType: 0, chatTypeId: 0,
                            inlineChatType: false, senderName: emptyNbt(),
                            hasTarget: false, targetName: emptyNbt())
  result.globalIndex = readVarInt(r)
  result.sender = readUuid(r)
  result.index = readVarInt(r)
  result.hasSignature = readBool(r)
  if result.hasSignature and ok(r):
    if SignatureBytes > remaining(r):
      fail(r, "a chat signature runs past the end")
      return
    r.at = r.at + SignatureBytes
  result.plain = readString(r)
  result.timestamp = readLong(r)
  result.salt = readLong(r)
  readPreviousMessages(r, result.previousCount)
  if not ok(r): return
  result.hasUnsigned = readBool(r)
  if result.hasUnsigned and ok(r):
    result.unsigned = readNbt(r)
    if result.unsigned.problem.len > 0:
      fail(r, result.unsigned.problem)
      return
  result.filterType = readVarInt(r)
  if result.filterType == FilterPartiallyFiltered and ok(r):
    # A bitset over the words of the message, one long per 64 words.
    let n = readVarInt(r)
    if not ok(r): return
    if n < 0 or n > 64:
      fail(r, "a filter mask longer than any message")
      return
    var i = 0
    while i < n:
      discard readLong(r)
      inc i
  readChatTypeHolder(r, result.chatTypeId, result.inlineChatType)
  if not ok(r): return
  result.senderName = readNbt(r)
  if result.senderName.problem.len > 0:
    fail(r, result.senderName.problem)
    return
  result.hasTarget = readBool(r)
  if result.hasTarget and ok(r):
    result.targetName = readNbt(r)
    if result.targetName.problem.len > 0: fail(r, result.targetName.problem)

proc saidBy*(p: PlayerChatPacket): string =
  ## The sender name as plain text, which is the part a log line wants.
  plain(p.senderName)

# ---------------------------------------------------------------------------
# Sending

proc bodyChatAck*(count: int): seq[int] =
  ## `chat_ack`: how many messages this client has seen. Cheap, and a server
  ## that has sent twenty unacknowledged messages stops relaying until it
  ## arrives, so a client that never sends it goes quiet.
  var w = writer()
  putVarInt(w, count)
  w.data

proc bodyChatUnsigned*(message: string; timestamp, salt, offset: int;
                       acknowledged: seq[int]; checksum: int): seq[int] =
  ## A chat message with **no signature**. Accepted whenever the join packets
  ## `enforcesSecureChat` was false, refused otherwise - see the file prose.
  ## `acknowledged` is the three-byte window; anything shorter is padded, which
  ## is what an empty window is.
  var w = writer()
  putString(w, message)
  putLong(w, timestamp)
  putLong(w, salt)
  putBool(w, false)                  # the signature option, absent
  putVarInt(w, offset)
  var i = 0
  while i < AcknowledgedBytes:
    if i < acknowledged.len: putByte(w, acknowledged[i]) else: putByte(w, 0)
    inc i
  putByte(w, checksum)
  w.data

proc bodyChatCommand*(command: string): seq[int] =
  ## `chat_command`, which is never signed. A command with signable arguments
  ## goes through `chat_command_signed` instead and needs everything the prose
  ## lists; a command without them - which is nearly all of them - is this.
  ## The leading slash is **not** sent.
  var w = writer()
  putString(w, command)
  w.data
