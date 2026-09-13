## JSON, as a flat arena rather than a tree.
##
## Pure: nothing here calls the host, so it compiles both inside the mod and
## inside `Tests/minecraft_test.nim`, which is the only reason the model rules
## below it can be proved without Unity anywhere near them.
##
## The shape is the one `aoughwl.gltf` uses - parallel seqs, a value named
## by its index - with the one change a Minecraft model needs: a document is a
## value, not a set of globals. A model's parent chain is five or six documents
## that all have to be readable *at once*, because the elements come from one of
## them and the texture variables come from all of them. The old importer kept
## one arena in globals and re-used it per parent, so it had to stop walking the
## chain the moment it found elements - and that is exactly the bug that makes a
## texture variable defined two levels up resolve to nothing.
##
## Malformed input sets `problem` and yields a null; it never reads off the end
## of the string and it never fails an assertion. A caller checks `problem`.

const
  jNull* = 0
  jBool* = 1
  jNumber* = 2
  jString* = 3
  jArray* = 4
  jObject* = 5

  MaxNesting = 64
    ## A block model is `parent`, `textures`, `elements`, a face, a uv - six
    ## deep. Sixty-four is far past anything Mojang ships and stops a file of
    ## forty thousand open brackets from taking the interpreter's stack with it.

type
  Json* = object
    kind*: seq[int]
    num*: seq[float]
    text*: seq[string]
    key*: seq[string]
    first*: seq[int]
    count*: seq[int]
    kids*: seq[int]
    root*: int
    problem*: string

  Cursor = object
    src: string
    pos: int
    depth: int

proc fail(doc: var Json; why: string) =
  if doc.problem.len == 0: doc.problem = why

proc node(doc: var Json; kind: int): int =
  doc.kind.add kind
  doc.num.add 0.0
  doc.text.add ""
  doc.key.add ""
  doc.first.add 0
  doc.count.add 0
  doc.kind.len - 1

proc one(c: char): string =
  ## A character as a string. `$` on a char is not a thing in this dialect, and
  ## every use of it here is putting an offending byte into a message.
  result = ""
  result.add c

proc white(c: char): bool =
  c == ' ' or c == '\t' or c == '\n' or c == '\r'

proc space(cur: var Cursor) =
  while cur.pos < cur.src.len and white(cur.src[cur.pos]): inc cur.pos

proc hexOf(c: char): int =
  if c >= '0' and c <= '9': int(c) - int('0')
  elif c >= 'a' and c <= 'f': int(c) - int('a') + 10
  elif c >= 'A' and c <= 'F': int(c) - int('A') + 10
  else: -1

proc addRune(s: var string; code: int) =
  ## The escapes a resource pack actually carries are ASCII, but a `\u` is legal
  ## anywhere so it is decoded rather than skipped. UTF-8, and a lone surrogate
  ## becomes the replacement character rather than an invalid sequence.
  var c = code
  if c >= 0xD800 and c <= 0xDFFF: c = 0xFFFD
  if c < 0x80:
    s.add char(c)
  elif c < 0x800:
    s.add char(0xC0 or (c shr 6))
    s.add char(0x80 or (c and 0x3F))
  elif c < 0x10000:
    s.add char(0xE0 or (c shr 12))
    s.add char(0x80 or ((c shr 6) and 0x3F))
    s.add char(0x80 or (c and 0x3F))
  else:
    s.add char(0xF0 or (c shr 18))
    s.add char(0x80 or ((c shr 12) and 0x3F))
    s.add char(0x80 or ((c shr 6) and 0x3F))
    s.add char(0x80 or (c and 0x3F))

proc parseString(doc: var Json; cur: var Cursor): string =
  result = ""
  inc cur.pos
  var closed = false
  while cur.pos < cur.src.len:
    let c = cur.src[cur.pos]
    if c == '"':
      inc cur.pos
      closed = true
      break
    if c == '\\':
      inc cur.pos
      if cur.pos >= cur.src.len: break
      let e = cur.src[cur.pos]
      case e
      of 'n': result.add '\n'
      of 't': result.add '\t'
      of 'r': result.add '\r'
      of 'b': result.add '\b'
      of 'f': result.add '\f'
      of '/': result.add '/'
      of '\\': result.add '\\'
      of '"': result.add '"'
      of 'u':
        var code = 0
        var got = 0
        while got < 4 and cur.pos + 1 < cur.src.len:
          let d = hexOf(cur.src[cur.pos + 1])
          if d < 0: break
          code = code * 16 + d
          inc cur.pos
          inc got
        if got < 4:
          fail(doc, "a \\u escape needs four hex digits")
          return result
        addRune(result, code)
      else:
        fail(doc, "'\\" & one(e) & "' is not an escape")
        return result
      inc cur.pos
    else:
      result.add c
      inc cur.pos
  if not closed: fail(doc, "a string is never closed")

proc digitOf(c: char): int =
  if c >= '0' and c <= '9': int(c) - int('0') else: -1

proc parseNumber(doc: var Json; cur: var Cursor): float =
  var sign = 1.0
  if cur.pos < cur.src.len and cur.src[cur.pos] == '-':
    sign = -1.0
    inc cur.pos
  elif cur.pos < cur.src.len and cur.src[cur.pos] == '+':
    inc cur.pos
  var digits = 0
  var whole = 0.0
  while cur.pos < cur.src.len and digitOf(cur.src[cur.pos]) >= 0:
    whole = whole * 10.0 + float(digitOf(cur.src[cur.pos]))
    inc cur.pos
    inc digits
  if cur.pos < cur.src.len and cur.src[cur.pos] == '.':
    inc cur.pos
    var scale = 0.1
    while cur.pos < cur.src.len and digitOf(cur.src[cur.pos]) >= 0:
      whole = whole + float(digitOf(cur.src[cur.pos])) * scale
      scale = scale * 0.1
      inc cur.pos
      inc digits
  if digits == 0:
    fail(doc, "a number with no digits in it")
    return 0.0
  if cur.pos < cur.src.len and (cur.src[cur.pos] == 'e' or cur.src[cur.pos] == 'E'):
    inc cur.pos
    var esign = 1
    if cur.pos < cur.src.len and (cur.src[cur.pos] == '+' or cur.src[cur.pos] == '-'):
      if cur.src[cur.pos] == '-': esign = -1
      inc cur.pos
    var e = 0
    var edigits = 0
    while cur.pos < cur.src.len and digitOf(cur.src[cur.pos]) >= 0:
      e = e * 10 + digitOf(cur.src[cur.pos])
      inc cur.pos
      inc edigits
      if e > 400: e = 400
    if edigits == 0:
      fail(doc, "an exponent with no digits in it")
      return 0.0
    var i = 0
    while i < e:
      if esign > 0: whole = whole * 10.0 else: whole = whole * 0.1
      inc i
  sign * whole

proc word(cur: var Cursor; want: string): bool =
  if cur.pos + want.len > cur.src.len: return false
  var i = 0
  while i < want.len:
    if cur.src[cur.pos + i] != want[i]: return false
    inc i
  cur.pos = cur.pos + want.len
  true

proc parseValue(doc: var Json; cur: var Cursor): int

proc parseObject(doc: var Json; cur: var Cursor): int =
  let me = node(doc, jObject)
  inc cur.pos
  var mine: seq[int] = @[]
  space(cur)
  if cur.pos < cur.src.len and cur.src[cur.pos] == '}':
    inc cur.pos
  else:
    while true:
      space(cur)
      if cur.pos >= cur.src.len or cur.src[cur.pos] != '"':
        fail(doc, "an object key must be a string")
        break
      let k = parseString(doc, cur)
      if doc.problem.len > 0: break
      space(cur)
      if cur.pos >= cur.src.len or cur.src[cur.pos] != ':':
        fail(doc, "an object key must be followed by ':'")
        break
      inc cur.pos
      let v = parseValue(doc, cur)
      if doc.problem.len > 0: break
      doc.key[v] = k
      mine.add v
      space(cur)
      if cur.pos < cur.src.len and cur.src[cur.pos] == ',':
        inc cur.pos
        continue
      if cur.pos < cur.src.len and cur.src[cur.pos] == '}':
        inc cur.pos
      else:
        fail(doc, "an object is never closed")
      break
  doc.first[me] = doc.kids.len
  doc.count[me] = mine.len
  var i = 0
  while i < mine.len:
    doc.kids.add mine[i]
    inc i
  me

proc parseArray(doc: var Json; cur: var Cursor): int =
  let me = node(doc, jArray)
  inc cur.pos
  var mine: seq[int] = @[]
  space(cur)
  if cur.pos < cur.src.len and cur.src[cur.pos] == ']':
    inc cur.pos
  else:
    while true:
      let v = parseValue(doc, cur)
      if doc.problem.len > 0: break
      mine.add v
      space(cur)
      if cur.pos < cur.src.len and cur.src[cur.pos] == ',':
        inc cur.pos
        continue
      if cur.pos < cur.src.len and cur.src[cur.pos] == ']':
        inc cur.pos
      else:
        fail(doc, "an array is never closed")
      break
  doc.first[me] = doc.kids.len
  doc.count[me] = mine.len
  var i = 0
  while i < mine.len:
    doc.kids.add mine[i]
    inc i
  me

proc parseValue(doc: var Json; cur: var Cursor): int =
  space(cur)
  if cur.pos >= cur.src.len:
    fail(doc, "the file ends in the middle of a value")
    return node(doc, jNull)
  if cur.depth >= MaxNesting:
    fail(doc, "nested more than " & $MaxNesting & " deep")
    return node(doc, jNull)
  inc cur.depth
  let c = cur.src[cur.pos]
  var me = 0
  if c == '{':
    me = parseObject(doc, cur)
  elif c == '[':
    me = parseArray(doc, cur)
  elif c == '"':
    me = node(doc, jString)
    doc.text[me] = parseString(doc, cur)
  elif c == 't':
    me = node(doc, jBool)
    if word(cur, "true"): doc.num[me] = 1.0
    else: fail(doc, "'t' begins nothing but true")
  elif c == 'f':
    me = node(doc, jBool)
    if not word(cur, "false"): fail(doc, "'f' begins nothing but false")
  elif c == 'n':
    me = node(doc, jNull)
    if not word(cur, "null"): fail(doc, "'n' begins nothing but null")
  elif c == '-' or c == '+' or digitOf(c) >= 0:
    me = node(doc, jNumber)
    doc.num[me] = parseNumber(doc, cur)
  else:
    fail(doc, "'" & one(c) & "' begins no value")
    me = node(doc, jNull)
  dec cur.depth
  me

## Read a whole document. `problem` is empty when it went through, and says what
## went wrong when it did not; `root` is -1 in that case, so every accessor
## below answers the empty thing rather than reading a node that is not there.
proc parseJson*(src: string): Json =
  result = Json(kind: @[], num: @[], text: @[], key: @[], first: @[],
                count: @[], kids: @[], root: -1, problem: "")
  var cur = Cursor(src: src, pos: 0, depth: 0)
  let top = parseValue(result, cur)
  if result.problem.len > 0:
    result.root = -1
    return result
  space(cur)
  if cur.pos < cur.src.len:
    result.problem = "there is more after the end of the document"
    result.root = -1
    return result
  result.root = top

## Every accessor takes an index that may be -1 and answers something rather
## than failing, because a model file is other people's data and half of what a
## reader asks for is legitimately absent.
proc member*(doc: Json; node: int; key: string): int =
  if node < 0 or node >= doc.kind.len or doc.kind[node] != jObject: return -1
  var i = 0
  while i < doc.count[node]:
    let child = doc.kids[doc.first[node] + i]
    if doc.key[child] == key: return child
    inc i
  -1

proc len*(doc: Json; node: int): int =
  if node < 0 or node >= doc.kind.len: 0 else: doc.count[node]

proc item*(doc: Json; node, index: int): int =
  if node < 0 or node >= doc.kind.len: return -1
  if index < 0 or index >= doc.count[node]: return -1
  doc.kids[doc.first[node] + index]

proc keyAt*(doc: Json; node: int): string =
  if node < 0 or node >= doc.kind.len: "" else: doc.key[node]

proc kindAt*(doc: Json; node: int): int =
  if node < 0 or node >= doc.kind.len: jNull else: doc.kind[node]

proc number*(doc: Json; node: int; fallback = 0.0): float =
  if node < 0 or node >= doc.kind.len: return fallback
  if doc.kind[node] == jNumber: doc.num[node]
  elif doc.kind[node] == jBool: doc.num[node]
  else: fallback

proc text*(doc: Json; node: int): string =
  if node < 0 or node >= doc.kind.len or doc.kind[node] != jString: ""
  else: doc.text[node]

proc truth*(doc: Json; node: int; fallback = false): bool =
  if node < 0 or node >= doc.kind.len or doc.kind[node] != jBool: fallback
  else: doc.num[node] > 0.5

## A [x, y, z] or [a, b, c, d] read into plain numbers, with a fallback for
## every slot the array did not have. Nothing in a model file is required to be
## the length it usually is.
proc numberAt*(doc: Json; node, index: int; fallback = 0.0): float =
  number(doc, item(doc, node, index), fallback)
