## The connection state machine, as pure state and a table.
##
## Handshake -> Status, or Handshake -> Login -> Configuration -> Play. What a
## packet id *means* depends on which of those the connection is in and which
## way the packet is going, so a decoder that reads ids without tracking state
## is not a decoder, it is a coincidence. Nothing here touches a socket: it is
## fed packet ids and it answers with names and transitions, which is exactly
## what lets the same code drive a real connection later and a recorded byte
## stream in the test now.
##
## Target: **protocol 774 (1.21.11)**.
##
## WHY THE PLAY TABLE IS NOT BUILT IN. Handshake, Status, Login and
## Configuration ids have been stable across many versions and are written out
## below. Play ids are renumbered nearly every release - they are assigned by
## declaration order in the server's own source - so a hardcoded Play table is a
## table that is silently wrong on the next version and on every modded server.
## So the table is a registry a caller fills from a version profile, and the
## built-in rows stop where confidence stops. `declare` is how a profile is
## loaded, and `nameOf` answers `"unknown"` rather than guessing.
##
## THE TRANSITIONS ARE PACKET-DRIVEN, and only these five move the connection:
##
##   Handshake     serverbound  Intention with intent 1  -> Status
##   Handshake     serverbound  Intention with intent 2  -> Login
##   Login         clientbound  Login Success            -> login succeeded
##   Login         serverbound  Login Acknowledged       -> Configuration
##   Configuration serverbound  Finish Configuration     -> Play
##
## Note the two that are easy to get wrong. `Set Compression` does *not* change
## state, it changes framing, and it arrives before `Login Success`. And the
## move into Configuration is driven by the client's acknowledgement, not by the
## server's success - a client that switches on `Login Success` reads the next
## packet out of the wrong table. Both are asserted in `Tests/mcnet_test.nim`,
## and both have a control that fails if the rule is removed.

import netwire

const
  StateHandshake* = 0
  StateStatus* = 1
  StateLogin* = 2
  StateConfiguration* = 3
  StatePlay* = 4
  StateClosed* = 5

  ToServer* = 0
  ToClient* = 1

  IntentStatus* = 1
  IntentLogin* = 2
  IntentTransfer* = 3

  ProtocolVersion* = 774
    ## 1.21.11, read out of `version.json` in the player's own jar rather than
    ## off a page: `"protocol_version": 774`.

  # Handshake, serverbound
  IdIntention* = 0x00

  # Status
  IdStatusRequest* = 0x00
  IdPingRequest* = 0x01
  IdStatusResponse* = 0x00
  IdPongResponse* = 0x01

  # Login, serverbound
  IdHello* = 0x00
  IdEncryptionResponse* = 0x01
  IdLoginPluginResponse* = 0x02
  IdLoginAcknowledged* = 0x03
  IdLoginCookieResponse* = 0x04

  # Login, clientbound
  IdLoginDisconnect* = 0x00
  IdEncryptionRequest* = 0x01
  IdLoginSuccess* = 0x02
  IdSetCompression* = 0x03
  IdLoginPluginRequest* = 0x04
  IdLoginCookieRequest* = 0x05

  # Configuration, serverbound
  IdClientInformation* = 0x00
  IdConfigCookieResponse* = 0x01
  IdConfigPluginMessage* = 0x02
  IdFinishConfiguration* = 0x03
  IdConfigKeepAlive* = 0x04
  IdPong* = 0x05
  IdResourcePackResponse* = 0x06
  IdKnownPacks* = 0x07

  # Configuration, clientbound
  IdConfigCookieRequest* = 0x00
  IdConfigPluginMessageOut* = 0x01
  IdConfigDisconnect* = 0x02
  IdFinishConfigurationOut* = 0x03
  IdConfigKeepAliveOut* = 0x04
  IdPing* = 0x05
  IdResetChat* = 0x06
  IdRegistryData* = 0x07
  IdRemoveResourcePack* = 0x08
  IdAddResourcePack* = 0x09
  IdStoreCookie* = 0x0A
  IdTransfer* = 0x0B
  IdFeatureFlags* = 0x0C
  IdUpdateTags* = 0x0D
  IdKnownPacksOut* = 0x0E

type
  Entry* = object
    state*, dir*, id*: int
    name*: string

  Table* = object
    entries*: seq[Entry]

  Connection* = object
    state*: int
    threshold*: int      ## mirrors the framing layer's, so a transcript can be
                         ## replayed without one
    loginSucceeded*: bool
    finished*: bool      ## Finish Configuration was acknowledged
    problem*: string

proc stateName*(state: int): string =
  if state == StateHandshake: "handshake"
  elif state == StateStatus: "status"
  elif state == StateLogin: "login"
  elif state == StateConfiguration: "configuration"
  elif state == StatePlay: "play"
  else: "closed"

proc emptyTable*(): Table =
  Table(entries: @[])

proc declare*(t: var Table; state, dir, id: int; name: string) =
  ## Add or replace one row. Replacing rather than appending is what makes a
  ## version profile able to correct a built-in row instead of shadowing it.
  var i = 0
  while i < t.entries.len:
    let e = t.entries[i]
    if e.state == state and e.dir == dir and e.id == id:
      t.entries[i] = Entry(state: state, dir: dir, id: id, name: name)
      return
    inc i
  t.entries.add Entry(state: state, dir: dir, id: id, name: name)

proc nameOf*(t: Table; state, dir, id: int): string =
  var i = 0
  while i < t.entries.len:
    let e = t.entries[i]
    if e.state == state and e.dir == dir and e.id == id: return e.name
    inc i
  result = "unknown"

proc idOf*(t: Table; state, dir: int; name: string): int =
  ## -1 when the table does not carry it, which is how a caller finds out that
  ## a version profile is missing rather than sending packet zero.
  var i = 0
  while i < t.entries.len:
    let e = t.entries[i]
    if e.state == state and e.dir == dir and e.name == name: return e.id
    inc i
  result = -1

proc knownTable*(): Table =
  ## Everything up to and including Configuration, under the game's **own**
  ## resource names, so that a row here and a row in the jar's generated
  ## `packets.json` are the same row and can be compared without a translation
  ## table in between. `Tests/mcnet_test.nim` does exactly that comparison
  ## against a report generated from the player's own jar, which is what makes
  ## this a checked table rather than a remembered one. Play is deliberately
  ## empty: 66% of the shared ids moved between 774 and 776, so a Play row that
  ## is not read out of the jar is a Play row that is wrong.
  result = emptyTable()
  declare(result, StateHandshake, ToServer, IdIntention, "minecraft:intention")

  declare(result, StateStatus, ToServer, IdStatusRequest, "minecraft:status_request")
  declare(result, StateStatus, ToServer, IdPingRequest, "minecraft:ping_request")
  declare(result, StateStatus, ToClient, IdStatusResponse, "minecraft:status_response")
  declare(result, StateStatus, ToClient, IdPongResponse, "minecraft:pong_response")

  declare(result, StateLogin, ToServer, IdHello, "minecraft:hello")
  declare(result, StateLogin, ToServer, IdEncryptionResponse, "minecraft:key")
  declare(result, StateLogin, ToServer, IdLoginPluginResponse, "minecraft:custom_query_answer")
  declare(result, StateLogin, ToServer, IdLoginAcknowledged, "minecraft:login_acknowledged")
  declare(result, StateLogin, ToServer, IdLoginCookieResponse, "minecraft:cookie_response")
  declare(result, StateLogin, ToClient, IdLoginDisconnect, "minecraft:login_disconnect")
  declare(result, StateLogin, ToClient, IdEncryptionRequest, "minecraft:hello")
  declare(result, StateLogin, ToClient, IdLoginSuccess, "minecraft:login_finished")
  declare(result, StateLogin, ToClient, IdSetCompression, "minecraft:login_compression")
  declare(result, StateLogin, ToClient, IdLoginPluginRequest, "minecraft:custom_query")
  declare(result, StateLogin, ToClient, IdLoginCookieRequest, "minecraft:cookie_request")

  declare(result, StateConfiguration, ToServer, IdClientInformation, "minecraft:client_information")
  declare(result, StateConfiguration, ToServer, IdConfigCookieResponse, "minecraft:cookie_response")
  declare(result, StateConfiguration, ToServer, IdConfigPluginMessage, "minecraft:custom_payload")
  declare(result, StateConfiguration, ToServer, IdFinishConfiguration, "minecraft:finish_configuration")
  declare(result, StateConfiguration, ToServer, IdConfigKeepAlive, "minecraft:keep_alive")
  declare(result, StateConfiguration, ToServer, IdPong, "minecraft:pong")
  declare(result, StateConfiguration, ToServer, IdResourcePackResponse, "minecraft:resource_pack")
  declare(result, StateConfiguration, ToServer, IdKnownPacks, "minecraft:select_known_packs")
  declare(result, StateConfiguration, ToClient, IdConfigCookieRequest, "minecraft:cookie_request")
  declare(result, StateConfiguration, ToClient, IdConfigPluginMessageOut, "minecraft:custom_payload")
  declare(result, StateConfiguration, ToClient, IdConfigDisconnect, "minecraft:disconnect")
  declare(result, StateConfiguration, ToClient, IdFinishConfigurationOut, "minecraft:finish_configuration")
  declare(result, StateConfiguration, ToClient, IdConfigKeepAliveOut, "minecraft:keep_alive")
  declare(result, StateConfiguration, ToClient, IdPing, "minecraft:ping")
  declare(result, StateConfiguration, ToClient, IdResetChat, "minecraft:reset_chat")
  declare(result, StateConfiguration, ToClient, IdRegistryData, "minecraft:registry_data")
  declare(result, StateConfiguration, ToClient, IdRemoveResourcePack, "minecraft:resource_pack_pop")
  declare(result, StateConfiguration, ToClient, IdAddResourcePack, "minecraft:resource_pack_push")
  declare(result, StateConfiguration, ToClient, IdStoreCookie, "minecraft:store_cookie")
  declare(result, StateConfiguration, ToClient, IdTransfer, "minecraft:transfer")
  declare(result, StateConfiguration, ToClient, IdFeatureFlags, "minecraft:update_enabled_features")
  declare(result, StateConfiguration, ToClient, IdUpdateTags, "minecraft:update_tags")
  declare(result, StateConfiguration, ToClient, IdKnownPacksOut, "minecraft:select_known_packs")

proc connection*(): Connection =
  Connection(state: StateHandshake, threshold: -1, loginSucceeded: false,
             finished: false, problem: "")

proc note*(c: var Connection; why: string) =
  if c.problem.len == 0: c.problem = why
  c.state = StateClosed

proc onPacket*(c: var Connection; dir, id: int; payload: var Reader) =
  ## Advance the connection by one packet. `payload` is positioned after the id
  ## and is read only where the transition depends on a field - the intent of a
  ## handshake and the threshold of a Set Compression - so this stays cheap and
  ## stays honest about which fields it is relying on.
  if c.state == StateClosed: return

  if c.state == StateHandshake:
    if dir != ToServer or id != IdIntention:
      note(c, "the first packet was not an intention")
      return
    discard readVarInt(payload)          # protocol version
    discard readString(payload)          # host
    discard readUShort(payload)          # port
    let intent = readVarInt(payload)
    if not ok(payload):
      note(c, "a truncated intention")
      return
    if intent == IntentStatus: c.state = StateStatus
    elif intent == IntentLogin or intent == IntentTransfer: c.state = StateLogin
    else: note(c, "an intention this client does not know")
    return

  if c.state == StateStatus:
    return                                # status never changes state

  if c.state == StateLogin:
    if dir == ToClient and id == IdSetCompression:
      let threshold = readVarInt(payload)
      if not ok(payload):
        note(c, "a truncated set compression")
        return
      # Framing changes here and state does not. Getting this the other way
      # round is the classic login bug.
      c.threshold = threshold
      return
    if dir == ToClient and id == IdLoginSuccess:
      c.loginSucceeded = true
      return
    if dir == ToServer and id == IdLoginAcknowledged:
      if not c.loginSucceeded:
        note(c, "acknowledged a login that had not succeeded")
        return
      c.state = StateConfiguration
      return
    if dir == ToClient and id == IdLoginDisconnect:
      note(c, "the server refused the login")
      return
    return

  if c.state == StateConfiguration:
    if dir == ToServer and id == IdFinishConfiguration:
      c.finished = true
      c.state = StatePlay
      return
    if dir == ToClient and id == IdConfigDisconnect:
      note(c, "the server disconnected during configuration")
      return
    return
