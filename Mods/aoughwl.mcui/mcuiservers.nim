## The server list, and Direct Connect.
##
## Minecraft's `GuiMultiplayer` is a list of servers you have added, each with a
## name, an address and a status, and six buttons under it: Join, Direct
## Connect, Add Server, Edit, Delete and Refresh. The list, the buttons and the
## Add/Direct forms are here, as arithmetic.
##
## ## What this build can really do, and what it cannot
##
## Jester has a real network underneath: `hostGame(port, password, name)` opens
## a listening socket, `joinGame(address, port, password, name)` is a plain TCP
## connect with a password handshake, and the server relays every message to
## every other peer. So Join and Direct Connect are not decoration - they reach
## a real session on a real address, and a world can be shared over them.
##
## Three things Minecraft's screen does are **not** possible here, and the
## screen says so rather than drawing them greyed out and hoping:
##
## **There is no ping.** The only way to find out whether an address is alive is
## to connect to it, and `joinGame` blocks for up to five seconds. Probing a
## list of twenty servers would stall the game for a minute and a half. So no
## row shows a latency bar, a player count or a MOTD, and `Refresh` is not
## offered. A row that showed five green bars for a machine that has been off
## for a week would be worse than a row that shows nothing.
##
## **There is no discovery.** No LAN broadcast, no master server, no lobby
## service. A server is somewhere you were told about, which is why Add Server
## and Direct Connect are the only two ways into the list.
##
## **There is no server icon**, for the same reason there is no ping: it arrives
## in the status handshake this transport does not have.
##
## `Refresh` is therefore absent rather than present-and-dead, and
## `multiplayer.status.unknown` is what a row says about itself. Both of those
## are deliberate and both are the honest version.
##
## ## Keys
##
## `multiplayer.title`, `selectServer.select`, `selectServer.direct`,
## `selectServer.add`, `selectServer.edit`, `selectServer.delete`,
## `selectServer.defaultName`, `addServer.title`, `addServer.enterName`,
## `addServer.enterIp`, `addServer.add`, `multiplayer.status.unknown`,
## `gui.cancel`, `gui.done`. All Mojang's, none of them ours.

import mcuicore
import mcuilist
import mcuitext

const
  SrvTitle* = "multiplayer.title"
  SrvJoin* = "selectServer.select"
  SrvDirect* = "selectServer.direct"
  SrvAdd* = "selectServer.add"
  SrvEdit* = "selectServer.edit"
  SrvDelete* = "selectServer.delete"
  SrvCancel* = "gui.cancel"
  SrvDone* = "gui.done"
  SrvDefaultName* = "selectServer.defaultName"
  SrvAddTitle* = "addServer.title"
  SrvEnterName* = "addServer.enterName"
  SrvEnterIp* = "addServer.enterIp"
  SrvAddButton* = "addServer.add"
  SrvDirectTitle* = "selectServer.direct"
  SrvUnknownStatus* = "multiplayer.status.unknown"
  SrvConnecting* = "connect.connecting"
  SrvFailed* = "connect.failed"

  DefaultPort* = 27015
    ## Jester's own, not Minecraft's 25565: this is a Jester session on a Jester
    ## transport, and an address that defaulted to a port nothing here listens
    ## on would fail for a reason nobody could see.

  SrvNameTop* = 66
  SrvNameLabelTop* = 53
  SrvAddressTop* = 106
  SrvAddressLabelTop* = 93

type
  Server* = object
    name*: string     ## whatever the player called it
    address*: string  ## host, or host:port, exactly as typed
    port*: int

  ServerChoice* = object
    servers*: seq[Server]
    pick*: int
    scroll*: int

proc noServers*(): ServerChoice =
  ServerChoice(servers: @[], pick: -1, scroll: 0)

# ---------------------------------------------------------------------------
# Addresses

proc digitsOf(text: string): int =
  var value = 0
  var digits = 0
  var i = 0
  while i < text.len and text[i] >= '0' and text[i] <= '9':
    value = value * 10 + (int(text[i]) - int('0'))
    inc digits
    inc i
  if digits == 0 or i < text.len: -1 else: value

## An address split into the host and the port, `host:port` or a bare host. A
## port outside 1..65535 is not a port and the whole thing is treated as a host
## with the default - which keeps `::1` and anything else with a colon in it
## from being read as a port number, and keeps a typo costing a connection
## rather than a crash.
proc splitAddress*(typed: string; fallbackPort = DefaultPort): seq[string] =
  let text = trimmed(typed)
  var cut = -1
  var colons = 0
  var i = 0
  while i < text.len:
    if text[i] == ':':
      cut = i
      inc colons
    inc i
  # Exactly one colon, or it was never a port. An IPv6 address is a whole
  # address and reading its last character as a port number would send the
  # player somewhere else entirely.
  if cut < 0 or colons != 1: return @[text, $fallbackPort]
  var host = ""
  i = 0
  while i < cut:
    host.add text[i]
    inc i
  var tail = ""
  i = cut + 1
  while i < text.len:
    tail.add text[i]
    inc i
  let port = digitsOf(tail)
  if port < 1 or port > 65535: return @[text, $fallbackPort]
  @[host, $port]

proc hostOf*(typed: string): string = splitAddress(typed)[0]
proc portOf*(typed: string): int =
  let said = splitAddress(typed)[1]
  var value = 0
  var i = 0
  while i < said.len:
    value = value * 10 + (int(said[i]) - int('0'))
    inc i
  value

## Whether there is anything to connect to at all. Not a validation of the
## address - a host name this build cannot resolve is the transport's business,
## and a screen that refused `localhost` because it had no dots in it would be
## wrong.
proc connectable*(typed: string): bool = hostOf(typed).len > 0

# ---------------------------------------------------------------------------
# The registry

proc escapeField(text: string): string =
  result = ""
  var i = 0
  while i < text.len:
    let c = text[i]
    if c == '\\': result.add "\\\\"
    elif c == '\n': result.add "\\n"
    elif c == '\t': result.add "\\t"
    else: result.add c
    inc i

proc unescapeField(text: string): string =
  result = ""
  var i = 0
  while i < text.len:
    let c = text[i]
    if c == '\\' and i + 1 < text.len:
      let n = text[i + 1]
      i = i + 2
      if n == 'n': result.add '\n'
      elif n == 't': result.add '\t'
      elif n == '\\': result.add '\\'
      else:
        result.add c
        result.add n
    else:
      result.add c
      inc i

proc writeServers*(servers: seq[Server]): string =
  result = ""
  var i = 0
  while i < servers.len:
    result.add escapeField(servers[i].name) & "\t" &
      escapeField(servers[i].address) & "\n"
    inc i

proc readServers*(body: string): seq[Server] =
  result = @[]
  var line = ""
  var i = 0
  while i <= body.len:
    if i == body.len or body[i] == '\n':
      if line.len > 0:
        var name = ""
        var k = 0
        while k < line.len and line[k] != '\t':
          name.add line[k]
          inc k
        if k < line.len:
          var address = ""
          var m = k + 1
          while m < line.len:
            if line[m] != '\r': address.add line[m]
            inc m
          if address.len > 0:
            result.add Server(name: unescapeField(name),
              address: unescapeField(address), port: portOf(address))
      line = ""
    else:
      line.add body[i]
    inc i

proc withServer*(servers: seq[Server]; one: Server): seq[Server] =
  result = servers
  result.add one

proc withoutAt*(servers: seq[Server]; at: int): seq[Server] =
  result = @[]
  var i = 0
  while i < servers.len:
    if i != at: result.add servers[i]
    inc i

proc replacingAt*(servers: seq[Server]; at: int; one: Server): seq[Server] =
  result = @[]
  var i = 0
  while i < servers.len:
    if i == at: result.add one
    else: result.add servers[i]
    inc i

# ---------------------------------------------------------------------------
# Where everything is

proc serverBox*(guiW, guiH, rows: int): ListBox =
  listBox(ListTop, guiH - ListBottomTwoRows,
          guiW div 2 - ListWidth div 2, ListWidth, WorldRowHeight, rows)

type
  ServerAction* = enum
    NoServerAction, JoinServer, DirectConnect, AddServer, EditServer,
    DeleteServer, LeaveServers

  ServerButton* = object
    action*: ServerAction
    key*: string
    rect*: MRect
    enabled*: bool

## The buttons under the list, in `GuiMultiplayer`'s own places - less Refresh,
## which this transport cannot honour. Its 70 pixels are left empty rather than
## given to its neighbours, so the row still lines up with the game's.
proc serverFooter*(guiW, guiH: int; picked: bool): seq[ServerButton] =
  let mid = guiW div 2
  let up = footerRow(guiH, 0)
  let down = footerRow(guiH, 1)
  result = @[]
  result.add ServerButton(action: JoinServer, key: SrvJoin,
    rect: mrect(float(mid - 154), float(up), 100.0, 20.0), enabled: picked)
  result.add ServerButton(action: DirectConnect, key: SrvDirect,
    rect: mrect(float(mid - 50), float(up), 100.0, 20.0), enabled: true)
  result.add ServerButton(action: AddServer, key: SrvAdd,
    rect: mrect(float(mid + 54), float(up), 100.0, 20.0), enabled: true)
  result.add ServerButton(action: EditServer, key: SrvEdit,
    rect: mrect(float(mid - 154), float(down), 70.0, 20.0), enabled: picked)
  result.add ServerButton(action: DeleteServer, key: SrvDelete,
    rect: mrect(float(mid - 74), float(down), 70.0, 20.0), enabled: picked)
  result.add ServerButton(action: LeaveServers, key: SrvCancel,
    rect: mrect(float(mid + 80), float(down), 75.0, 20.0), enabled: true)

proc buttonUnder*(buttons: seq[ServerButton]; x, y: float): int =
  result = -1
  var i = 0
  while i < buttons.len:
    if buttons[i].rect.holds(x, y): return i
    inc i

# ---------------------------------------------------------------------------
# Add Server, and Direct Connect
#
# The same form with one field hidden: Direct Connect has no name because you
# are not keeping it. `AddServerScreen` and `DirectJoinServerScreen` really are
# the same screen in the game too.

type
  AddForm* = object
    name*: Field
    address*: Field
    onAddress*: bool
    keeping*: bool    ## Add Server keeps it; Direct Connect does not

proc addForm*(name = ""; address = ""; keeping = true): AddForm =
  var f = AddForm(name: field(name), address: field(address, MaxAddressLength),
                  onAddress: not keeping, keeping: keeping)
  if keeping:
    f.name.focused = true
  else:
    f.address.focused = true
  f

proc nextField*(f: var AddForm) =
  if not f.keeping: return
  f.onAddress = not f.onAddress
  f.name.focused = not f.onAddress
  f.address.focused = f.onAddress

proc serverNameRect*(guiW: int): MRect =
  mrect(float(guiW div 2 - FieldWidth div 2), float(SrvNameTop),
        float(FieldWidth), float(FieldHeight))

## Direct Connect has one field and it sits where Add Server's name is, because
## a single field belongs at the top of its own screen and not in the middle of
## the space a missing one left.
proc addressRect*(guiW: int; keeping: bool): MRect =
  let top = if keeping: SrvAddressTop else: SrvNameTop
  mrect(float(guiW div 2 - FieldWidth div 2), float(top), float(FieldWidth),
        float(FieldHeight))

proc srvAddressLabelTop*(keeping: bool): int =
  if keeping: SrvAddressLabelTop else: SrvNameLabelTop

proc acceptRect*(guiW, guiH: int): MRect =
  mrect(float(guiW div 2 - 100), float(guiH div 4 + 96), 200.0, 20.0)
proc backRect*(guiW, guiH: int): MRect =
  mrect(float(guiW div 2 - 100), float(guiH div 4 + 120), 200.0, 20.0)

proc formFieldUnder*(guiW: int; keeping: bool; x, y: float): int =
  if keeping and serverNameRect(guiW).holds(x, y): return 0
  if addressRect(guiW, keeping).holds(x, y): return 1
  -1

## What a kept server is called when the player left the name blank. The key,
## not a word: `selectServer.defaultName` is "Minecraft Server" in English and
## something else everywhere else.
proc nameOrKey*(f: AddForm): string =
  let t = trimmed(f.name.text)
  if t.len > 0: t else: SrvDefaultName
