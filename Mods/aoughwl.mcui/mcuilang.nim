## Every word on the screen, addressed by Minecraft's own translation key.
##
## This mod hard-codes no user-visible string. A button is not "Singleplayer",
## it is `menu.singleplayer`, and what the player reads is whatever their own
## `assets/minecraft/lang/<language>.json` says that key means. That is not a
## nicety about localisation - it is what makes the menu 1:1 by construction
## rather than by somebody typing out what they remember the button said. It
## also means the menu is in the player's language the moment they have a
## language file for it, with nothing in this mod knowing that any language
## exists.
##
## ## Where the table comes from
##
## `aoughwl.minecraft` owns the jar, the resource-pack layer stack and the
## JSON reader. It resolves `lang/<code>.json` through that stack - so a pack
## that overrides three strings overrides exactly three, key by key, with the
## jar underneath - and hands the result over the service boundary as a flat
## table: one `key<TAB>value` per line, with a backslash escape for the three
## characters that could not otherwise survive a line. This module parses that,
## and knows nothing about JSON, packs or files.
##
## ## Two rules that are the game's and not ours
##
## **A missing key shows as the key.** Minecraft draws `menu.singleplayer` when
## it cannot translate it, which is ugly and honest and immediately tells you
## what is wrong. Substituting invented English would hide a broken pack behind
## something that looks right, so this does what the game does.
##
## **Arguments are Java's format, not ours.** `%s` takes the next argument and
## `%1$s` takes a numbered one, because the language files are full of both -
## `chat.type.text` is `<%s> %s`, `multiplayer.player.joined` is `%s joined the
## game`, and a translator is free to reorder them with `%2$s %1$s` in a
## language where the order is different. `%%` is a literal per cent. Anything
## else after a per cent is left alone: a language file is other people's data
## and a malformed one must cost a strange-looking line, never the session.

const
  Buckets = 256
    ## A language file is a few thousand rows and a screen asks it a dozen
    ## questions. A flat scan would be a few tens of thousands of string
    ## compares a frame in an interpreter, so the table is bucketed on the way
    ## in. Nothing about the answer depends on this; it is only how fast.

type
  Lang* = object
    key*: seq[string]
    value*: seq[string]
    head*: seq[int]
    next*: seq[int]
    language*: string   ## which file this came from, for a status line
    problem*: string

proc noLang*(): Lang =
  Lang(key: @[], value: @[], head: @[], next: @[], language: "", problem: "")

proc bucketOf(key: string): int =
  var h = 0
  var i = 0
  while i < key.len:
    h = (h * 31 + int(key[i])) mod Buckets
    inc i
  if h < 0: h + Buckets else: h

## The escape a value carries over the boundary. Spelled here because the test
## asserts the round trip, and spelled *again* in `aoughwl.minecraft` -
## which cannot import this module across the mod boundary - so the two halves
## are two lines each and both are asserted against this one.
proc escapeValue*(text: string): string =
  result = ""
  var i = 0
  while i < text.len:
    let c = text[i]
    if c == '\\': result.add "\\\\"
    elif c == '\n': result.add "\\n"
    elif c == '\t': result.add "\\t"
    else: result.add c
    inc i

proc unescapeValue*(text: string): string =
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
        # Not an escape this side knows. Keep both characters rather than
        # eating one: a language file is other people's data.
        result.add c
        result.add n
    else:
      result.add c
      inc i

## An empty table with its buckets laid out, ready to be filled a few rows at a
## time by `addRows`.
proc beginTable*(language = ""): Lang =
  result = noLang()
  result.language = language
  var i = 0
  while i < Buckets:
    result.head.add -1
    inc i

## Fold at most `rows` more lines of `body` into `l`, starting at byte `at` and
## leaving `at` on the first byte of the first line it has not read.
##
## **Why this is not one call any more.** `en_us.json` arrives as eight thousand
## one hundred and twenty-three rows of key and value, and reading all of them
## was measured at 4.5 seconds of interpreter string work inside a single
## update() - `tools/run_mod.exe --time` over this mod against
## `aoughwl.minecraft`, with the other side of the service boundary already
## spending 3.9 of its own. Nothing repaints while a mod is running, so that was
## a window that looked hung for eight and a half seconds, which is exactly what
## a player reported. The rows are the unit a caller budgets in; `main.nim`'s
## `askLang` is the caller and the budget adapts to the frame that just went by.
##
## Blank lines and lines with no tab in them are skipped; a later row of the
## same key wins, which is the rule a resource pack layered over the jar needs,
## and it still holds across calls because the rows keep their order.
proc addRows*(l: var Lang; body: string; at: var int; rows: int) =
  if l.head.len < Buckets: l = beginTable(l.language)
  var done = 0
  var line = ""
  var i = at
  while i < body.len and done < rows:
    let c = body[i]
    inc i
    if c != '\n':
      line.add c
      if i < body.len: continue
    # A line, either because it ended or because the body did.
    var k = ""
    var j = 0
    while j < line.len and line[j] != '\t':
      k.add line[j]
      inc j
    if k.len > 0 and j < line.len:
      var v = ""
      var m = j + 1
      while m < line.len:
        if line[m] != '\r': v.add line[m]
        inc m
      let b = bucketOf(k)
      l.key.add k
      l.value.add unescapeValue(v)
      # Pushed on the front of its bucket, so the row added last is the row
      # found first - which is how a pack's override wins over the jar's.
      l.next.add l.head[b]
      l.head[b] = l.key.len - 1
    line = ""
    inc done
    at = i

## The flat table, parsed, whole. The one-call spelling, for a table small
## enough that one call is honest - a test, a pack's three-row override - and
## the same answer `addRows` arrives at a budget at a time.
proc parseTable*(body: string; language = ""): Lang =
  result = beginTable(language)
  var at = 0
  while at < body.len:
    let before = at
    addRows(result, body, at, 256)
    if at == before: return result

proc count*(l: Lang): int = l.key.len

proc find*(l: Lang; key: string): int =
  if l.head.len < Buckets: return -1
  var at = l.head[bucketOf(key)]
  while at >= 0:
    if l.key[at] == key: return at
    at = l.next[at]
  -1

proc has*(l: Lang; key: string): bool = find(l, key) >= 0

## Java's `String.format` subset the language files actually use. `args` short
## of what the pattern asks for leaves the specifier standing, which is what
## makes a malformed row visible instead of fatal.
proc format*(pattern: string; args: seq[string]): string =
  result = ""
  var nextArg = 0
  var i = 0
  while i < pattern.len:
    let c = pattern[i]
    if c != '%':
      result.add c
      inc i
    elif i + 1 < pattern.len and pattern[i + 1] == '%':
      result.add '%'
      i = i + 2
    else:
      # `%s`, or `%<n>$s`. Anything else is not a specifier this understands.
      var j = i + 1
      var digits = ""
      while j < pattern.len and pattern[j] >= '0' and pattern[j] <= '9':
        digits.add pattern[j]
        inc j
      var which = -1
      var taken = false
      if j < pattern.len and digits.len > 0 and pattern[j] == '$' and
         j + 1 < pattern.len and pattern[j + 1] == 's':
        var n = 0
        var d = 0
        while d < digits.len:
          n = n * 10 + (int(digits[d]) - int('0'))
          inc d
        which = n - 1
        j = j + 2
        taken = true
      elif digits.len == 0 and j < pattern.len and pattern[j] == 's':
        which = nextArg
        inc nextArg
        inc j
        taken = true
      if taken and which >= 0 and which < args.len:
        result.add args[which]
        i = j
      elif taken:
        # A specifier with no argument behind it. Left exactly as written.
        var k = i
        while k < j:
          result.add pattern[k]
          inc k
        i = j
      else:
        result.add c
        inc i

## The whole of what this module is for: a key in, the player's own words out,
## and the key itself when the file has nothing to say about it.
proc translate*(l: Lang; key: string): string =
  let at = find(l, key)
  if at < 0: key else: l.value[at]

proc translate*(l: Lang; key: string; args: seq[string]): string =
  let at = find(l, key)
  if at < 0: format(key, args) else: format(l.value[at], args)

## The language file to ask for, from the player's own `options.txt`.
##
## The key is `lang` and the value is `en_us` on anything modern and `en_US` on
## anything before 1.11; the files are lower case either way from 1.11 on, and
## the layer stack is asked for both spellings, so this only lower-cases and
## leaves the deciding to whoever looks the file up.
proc languageFrom*(optionsValue: string): string =
  result = ""
  var i = 0
  while i < optionsValue.len:
    var c = optionsValue[i]
    if c >= 'A' and c <= 'Z': c = char(int(c) + 32)
    if c != '\r' and c != ' ': result.add c
    inc i
  if result.len == 0: result = "en_us"
