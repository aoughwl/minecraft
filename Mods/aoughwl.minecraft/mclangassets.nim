## Resolve translations from the selected installation's content-addressed store.
import jester
import importing
import mcjson

const Store = "Imported/language-assets"
var
  selected = ""
  phase = 0
  job = 0
  descriptor = ""
  indexId = ""
  codes: seq[string] = @[]
  hashes: seq[string] = @[]
  cursor = 0
  available: seq[string] = @[]
  files: seq[string] = @[]

proc languageAsset*(code: string): string =
  var i = 0
  while i < available.len:
    if available[i] == code: return files[i]
    inc i
  ""

proc assetLanguages*(): string =
  result = "en_us"
  for code in available:
    if code != "en_us": result.add "\n" & code

proc stepLanguageAssets*(root, jar: string) =
  if root.len == 0 or jar.len < 4: return
  let identity = root & "|" & jar
  if identity != selected:
    if job > 0:
      importCancel(job)
      importRelease(job)
    selected = identity
    phase = 0
    job = 0
    available = @[]
    files = @[]
    codes = @[]
    hashes = @[]
    cursor = 0
  if phase == 4: return
  if job > 0:
    if not importDone(job): return
    let problem = importError(job)
    importRelease(job)
    job = 0
    if problem.len > 0:
      log("[minecraft languages] " & problem)
      if phase != 3:
        phase = 4
        return
  if phase == 0:
    descriptor = jar[0 ..< jar.len - 4] & ".json"
    job = importExtract(root, descriptor, "*", Store & "/version")
    phase = 1
  elif phase == 1:
    var leaf = 0
    for i in 0 ..< descriptor.len:
      if descriptor[i] == '/' or descriptor[i] == '\\': leaf = i + 1
    let doc = parseJson(importRead(Store & "/version/" & descriptor[leaf .. ^1]))
    indexId = text(doc, member(doc, member(doc, doc.root, "assetIndex"), "id"))
    if indexId.len == 0:
      log("[minecraft languages] selected version has no asset index")
      phase = 4
      return
    job = importExtract(root, "assets/indexes/" & indexId & ".json", "*", Store & "/index")
    phase = 2
  elif phase == 2:
    let doc = parseJson(importRead(Store & "/index/" & indexId & ".json"))
    let objects = member(doc, doc.root, "objects")
    var i = 0
    while i < len(doc, objects):
      let entry = item(doc, objects, i)
      let name = keyAt(doc, entry)
      if name.len > 20 and name[0 ..< 15] == "minecraft/lang/" and
          name[name.len - 5 .. ^1] == ".json":
        let hash = text(doc, member(doc, entry, "hash"))
        var valid = hash.len == 40
        for c in hash:
          if not (c >= '0' and c <= '9' or c >= 'a' and c <= 'f'): valid = false
        if valid:
          codes.add name[15 ..< name.len - 5]
          hashes.add hash
      inc i
    phase = 3
  elif phase == 3:
    if cursor > 0:
      let file = Store & "/objects/" & hashes[cursor - 1]
      if importHas(file):
        available.add codes[cursor - 1]
        files.add file
    if cursor >= codes.len:
      log("[assert] minecraft.assetlanguages=" & $available.len)
      phase = 4
      return
    let hash = hashes[cursor]
    inc cursor
    job = importExtract(root, "assets/objects/" & hash[0 .. 1] & "/" & hash,
      "*", Store & "/objects")
  if job == 0 and phase != 3:
    log("[minecraft languages] " & importProblem())
    phase = 4
