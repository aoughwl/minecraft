## What to tell a player who has not got a Minecraft here yet - and which of the
## six different reasons it is.
##
## The complaint this module exists to answer was: *"if no minecraft is installed
## it should tell the player to install minecraft first - currently it allows me
## to go with it uninstalled."* The menu drew a placeholder and said nothing, and
## it drew the same placeholder whatever the reason was, so there was nothing to
## read and nothing to do.
##
## They are six states and they are not shades of one another:
##
## | | what is true | what to say |
## | --- | --- | --- |
## | `nogrant` | nothing has been granted | add a line to `imports.txt` |
## | `nojar` | a folder was granted and there is no Minecraft in it | **install Minecraft first** |
## | `importing` | it is being read now | how far it has got |
## | `notimported` | there is one and nothing has read it | it is about to be |
## | `mismatch` | a pack does not cover the version chosen | which, and which version would |
## | `ready` | nothing to say | nothing |
##
## `nogrant` and `nojar` are the pair that matters and the pair that is easy to
## collapse: one is "this game cannot see your disk", the other is "this game
## looked and there is no game there". Telling a player to edit `imports.txt`
## when they have already edited it, or telling them to install Minecraft when
## the real problem is a missing permission line, are both dead ends. So the two
## messages have nothing in common, and `Tests/mcui_test.exe` asserts that every
## state's message carries its own mark and none of anybody else's - which is an
## assertion that fails the moment two of them are answered by one sentence.
##
## Every line here is **ours**. None of it is Minecraft's and none of it pretends
## to be a translation key: there is nothing to translate against at this point,
## because the language file is inside the copy of Minecraft that is missing.

type
  GrantState* = enum
    UnknownGrant, NoGrant, NoJar, Importing, NotImported, PackMismatch, GrantReady

  Notice* = object
    ## The record `minecraft.gui`'s `notice` answers with, split up.
    state*: GrantState
    root*: string       ## the folder that was granted
    policy*: string     ## the file a grant goes in
    example*: string    ## what a line in it looks like on this machine
    version*: string    ## the Minecraft chosen
    progress*: string   ## how far the reading has got
    fit*: string        ## `<pack>|<low>|<high>|<format>|<version>|<better>`

proc stateOfWord*(word: string): GrantState =
  if word == "nogrant": NoGrant
  elif word == "nojar": NoJar
  elif word == "importing": Importing
  elif word == "notimported": NotImported
  elif word == "mismatch": PackMismatch
  elif word == "ready": GrantReady
  else: UnknownGrant

proc fields*(record: string; separator = '\t'): seq[string] =
  result = @[]
  var piece = ""
  var i = 0
  while i <= record.len:
    if i == record.len or record[i] == separator:
      result.add piece
      piece = ""
    else:
      piece.add record[i]
    inc i

proc pick(list: seq[string]; index: int): string =
  if index < list.len: list[index] else: ""

## The record, parsed. A short record is not an error: a provider that has not
## got round to a field yet answers with fewer, and every reader below treats a
## missing field as an empty one.
proc parseNotice*(record: string): Notice =
  let f = fields(record)
  Notice(state: stateOfWord(pick(f, 0)), root: pick(f, 1), policy: pick(f, 2),
         example: pick(f, 3), version: pick(f, 4), progress: pick(f, 5),
         fit: pick(f, 6))

## Whether this is a state the player has to do something about. `importing` is
## not - it is working - and `ready` is not. The other four are, and the menu
## draws them where they cannot be missed rather than in small grey type.
proc urgent*(n: Notice): bool =
  n.state == NoGrant or n.state == NoJar or n.state == PackMismatch

## Whether the menu is being drawn out of a real Minecraft.
proc settled*(n: Notice): bool = n.state == GrantReady

## The `fit` field, split. `pack`, `low`, `high`, `format`, `version`, `better`.
proc fitFields*(n: Notice): seq[string] = fields(n.fit, '|')

## What to put on the screen. Every line is ours and every line ends in
## something to do.
##
## The marks each state leaves are what the test holds it to: `nogrant` names
## the policy file and never the granted folder; `nojar` names the granted
## folder and `versions/` and never the policy file; `mismatch` names the pack
## and the two numbers and neither of the others. A single sentence covering two
## of these states would fail that immediately, which is the point.
proc noticeLines*(n: Notice): seq[string] =
  result = @[]
  if n.state == NoGrant:
    result.add "Minecraft has not been granted to this game yet."
    result.add "Add a line like this to " & n.policy
    result.add "        minecraft = " & n.example
    result.add "then come back here; this screen redraws itself."
    return result
  if n.state == NoJar:
    # The one the complaint was about. The permission is fine; there is no game.
    result.add "Install Minecraft first - there is none in the folder granted."
    result.add "Looked in " & n.root
    result.add "for versions/<version>/<version>.jar and found none."
    result.add "Run the Minecraft launcher once to download a version."
    return result
  if n.state == Importing:
    if n.progress.len > 0:
      result.add n.progress
    else:
      result.add "Preparing Minecraft data"
    return result
  if n.state == NotImported:
    if n.version.len > 0:
      result.add "Found Minecraft " & n.version & ". Reading it now."
    else:
      result.add "Found a Minecraft. Reading it now."
    result.add "Press M to read it again at any time."
    return result
  if n.state == PackMismatch:
    # Three lines, and in this order on purpose. This is the one state whose
    # notice shares the screen with a logo that is really there, so it has the
    # least room of the six and the caller cuts it from the bottom. What
    # survives a cut has to be the part somebody can act on, which is the last
    # line, so the two numbers - true, useful, and not actionable - go in the
    # middle where they are the first thing lost.
    let f = fitFields(n)
    result.add "Your resource pack does not cover this version of Minecraft."
    result.add pick(f, 0) & " wants pack formats " & pick(f, 1) & " to " &
      pick(f, 2) & "; " & pick(f, 4) & " speaks " & pick(f, 3) & "."
    if pick(f, 5).len > 0:
      result.add "Your " & pick(f, 5) & " install would fit it."
    else:
      result.add "Anything the pack has not got comes from the game itself."
    return result

## One line for the corner, whatever the state - short enough to sit under the
## menu without covering it.
proc statusLine*(n: Notice): string =
  if n.state == NoGrant: return "no Minecraft granted"
  if n.state == NoJar: return "no Minecraft installed"
  if n.state == Importing:
    if n.progress.len > 0: return n.progress
    return "reading Minecraft"
  if n.state == NotImported: return "Minecraft found, not read yet"
  if n.state == PackMismatch: return ""
  ""
