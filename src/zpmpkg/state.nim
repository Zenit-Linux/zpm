import std/[json, os, strformat, strutils]
import ./types

## Pokwitowania instalacji narzędzi `own` -- co zpm WIE NA PEWNO, że
## faktycznie wylądowało na danym `rootPath` (dla `git`: na jakim
## dokładnie commicie/refie). Osobny plik od bazy SQLite (`database.nim`)
## celowo -- ekosystem `own` działa też poza `zpm install` (np. `zpm own
## build-stage` w trybie `--root=...` buildera), gdzie nie zawsze jest
## sens dotykać głównej bazy hosta.
##
## Używane do:
##  - idempotencji: `installOwn`/`installManyOwn` nie odpalają build+
##    install ponownie, gdy dokładnie ten sam commit/sha256 jest już
##    zainstalowany na tym samym `rootPath`,
##  - reverse-dependency check przy `zpm own remove` (`directDependents`
##    z deps.nim + "czy dependent ma pokwitowanie" = "czy realnie stoi
##    na tym, co chcemy usunąć").

proc rootTag(rootPath: string): string =
  if rootPath.len == 0 or rootPath == "/": "host"
  else: rootPath.strip(chars = {'/'}).replace("/", "_")

proc receiptPath*(cfg: ZpmConfig, name, rootPath: string): string =
  cfg.ownStateDir / &"{name}@{rootTag(rootPath)}.json"

proc saveOwnReceipt*(cfg: ZpmConfig, r: OwnInstallReceipt) =
  createDir(cfg.ownStateDir)
  var j = newJObject()
  j["name"] = %r.name
  j["resolved_ref"] = %r.resolvedRef
  j["sha256"] = %r.sha256
  j["version"] = %r.version
  j["root_path"] = %r.rootPath
  j["installed_at"] = %r.installedAt
  let path = receiptPath(cfg, r.name, r.rootPath)
  let tmp = path & ".tmp"
  writeFile(tmp, j.pretty())
  moveFile(tmp, path)

proc loadOwnReceipt*(cfg: ZpmConfig, name, rootPath: string): tuple[found: bool, r: OwnInstallReceipt] =
  let path = receiptPath(cfg, name, rootPath)
  if not fileExists(path): return (false, OwnInstallReceipt())
  try:
    let j = parseJson(readFile(path))
    (true, OwnInstallReceipt(
      name: j{"name"}.getStr(""),
      resolvedRef: j{"resolved_ref"}.getStr(""),
      sha256: j{"sha256"}.getStr(""),
      version: j{"version"}.getStr(""),
      rootPath: j{"root_path"}.getStr(""),
      installedAt: j{"installed_at"}.getStr(""),
    ))
  except CatchableError:
    (false, OwnInstallReceipt())

proc removeOwnReceipt*(cfg: ZpmConfig, name, rootPath: string) =
  let path = receiptPath(cfg, name, rootPath)
  if fileExists(path): removeFile(path)

proc isOwnInstalled*(cfg: ZpmConfig, name, rootPath: string): bool =
  loadOwnReceipt(cfg, name, rootPath).found

proc allOwnReceipts*(cfg: ZpmConfig): seq[OwnInstallReceipt] =
  result = @[]
  if not dirExists(cfg.ownStateDir): return
  for f in walkFiles(cfg.ownStateDir / "*.json"):
    try:
      let j = parseJson(readFile(f))
      result.add OwnInstallReceipt(
        name: j{"name"}.getStr(""),
        resolvedRef: j{"resolved_ref"}.getStr(""),
        sha256: j{"sha256"}.getStr(""),
        version: j{"version"}.getStr(""),
        rootPath: j{"root_path"}.getStr(""),
        installedAt: j{"installed_at"}.getStr(""),
      )
    except CatchableError:
      discard
