#!/bin/sh
# namespace-check.sh: check that every compilation unit a package installs
# (or builds) carries the package prefix. See README.md.
set -u

usage() {
  cat >&2 <<'USAGE'
usage: namespace-check.sh [options] NAME=DIR [NAME=DIR ...]

  NAME=DIR            an inventory: configuration name and a directory searched
                      recursively (symlinks followed) for .cmi .cmj .cma .cmxa;
                      repeat NAME to merge several directories into one
                      configuration
  --prefix P          allowed normalized prefix, e.g. Rivet or Rivet_native_exec
                      (repeatable; comma lists accepted)
  --exceptions FILE   lines "CONFIG PROVIDER UNIT" (globs, # comments)
  --expect-libs FILE  lines "CONFIG PROVIDER" that must be present
  --ocamlobjinfo CMD  default: ocamlobjinfo
  --fail              exit 1 on any violation or missing library
  -q                  do not list conforming units
exit: 0 report or clean, 1 findings under --fail, 2 usage/missing/empty inventory
USAGE
  exit 2
}

fail=0 quiet=0 exc="" expect="" objinfo=ocamlobjinfo prefixes=""
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT INT HUP TERM
: >"$tmp/invs"

while [ $# -gt 0 ]; do
  case $1 in
    --prefix) [ $# -ge 2 ] || usage; prefixes="$prefixes,$2"; shift 2 ;;
    --prefix=*) prefixes="$prefixes,${1#*=}"; shift ;;
    --exceptions) [ $# -ge 2 ] || usage; exc=$2; shift 2 ;;
    --expect-libs) [ $# -ge 2 ] || usage; expect=$2; shift 2 ;;
    --ocamlobjinfo) [ $# -ge 2 ] || usage; objinfo=$2; shift 2 ;;
    --fail) fail=1; shift ;;
    -q) quiet=1; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *=*) printf '%s\n' "$1" >>"$tmp/invs"; shift ;;
    *) echo "not NAME=DIR: $1" >&2; usage ;;
  esac
done
[ -s "$tmp/invs" ] || { echo "no inventories given" >&2; usage; }

# normalize: '-' and '.' to '_', first letter upper, then lower-case compare
norm=$(printf '%s' "$prefixes" | tr ',' '\n' | sed -e '/^$/d' -e 's/[-.]/_/g' |
  awk '{ print toupper(substr($0,1,1)) substr($0,2) }' | tr '\n' ' ')
[ -n "$norm" ] || { echo "--prefix is required" >&2; usage; }
for f in "$exc" "$expect"; do
  [ -z "$f" ] || [ -r "$f" ] || { echo "cannot read $f" >&2; exit 2; }
done

err=0
: >"$tmp/recs"
while IFS= read -r spec; do
  name=${spec%%=*}
  dir=${spec#*=}
  if [ -z "$name" ] || [ -z "$dir" ]; then echo "ERROR: bad inventory '$spec'" >&2; err=1; continue; fi
  if [ ! -d "$dir" ]; then echo "ERROR: inventory '$name': directory missing: $dir" >&2; err=1; continue; fi
  root=$(cd "$dir" && pwd) || { err=1; continue; }
  root=${root%/}
  broken=$(find "$root" -type l -name '*.cm*' ! -exec test -e {} \; -print)
  if [ -n "$broken" ]; then
    echo "ERROR: inventory '$name': broken symlinks:" >&2; printf '%s\n' "$broken" >&2; err=1; continue
  fi
  find -L "$root" -type f \( -name '*.cmi' -o -name '*.cmj' -o -name '*.cma' -o -name '*.cmxa' \) |
    LC_ALL=C sort >"$tmp/files"
  if [ ! -s "$tmp/files" ]; then
    echo "ERROR: inventory '$name': empty (no .cmi .cmj .cma .cmxa under $root)" >&2; err=1; continue
  fi
  while IFS= read -r f; do
    base=${f##*/}; ext=${base##*.}; stem=${base%.*}
    case $ext in
      cmi|cmj) printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$root" "$ext" "$f" "$stem" ;;
      cma|cmxa)
        if ! out=$($objinfo "$f" 2>&1); then
          echo "ERROR: $objinfo failed on $f: $out" >&2; err=1; continue
        fi
        printf '%s\n' "$out" | sed -n -e 's/^Unit name: //p' -e 's/^Name: //p' |
          while IFS= read -r u; do printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$root" "$ext" "$f" "$u"; done ;;
    esac
  done <"$tmp/files" >>"$tmp/recs"
done <"$tmp/invs"
[ $err -eq 0 ] || { echo "FAILED: inventory problems above (exit 2)" >&2; exit 2; }

# stage 1: classify
awk -F '\t' -v prefixes="$norm" -v excf="$exc" -v expf="$expect" '
function glob2re(g,   i, c, r) {
  r = "^"
  for (i = 1; i <= length(g); i++) {
    c = substr(g, i, 1)
    if (c == "*") r = r ".*"
    else if (c == "?") r = r "."
    else if (index("\\^$.[]|()+{}/", c)) r = r "\\" c
    else r = r c
  }
  return r "$"
}
function gm(g, s) { return s ~ glob2re(g) }
function isdrop(c) {
  return c == ".private" || c == ".public_cmi" || c == ".objs" || c == "byte" || c == "native" || c == "melange"
}
function provider(root, path,   rel, n, p, i, out) {
  rel = substr(path, length(root) + 2)
  n = split(rel, p, "/"); out = ""
  for (i = 1; i < n; i++) if (!isdrop(p[i])) out = (out == "") ? p[i] : out "/" p[i]
  if (out == "") {
    n = split(root, p, "/")
    for (i = n; i >= 1; i--) if (p[i] != "" && !isdrop(p[i])) { out = p[i]; break }
  }
  return out
}
function conforming(top,   i, lt) {
  lt = tolower(top)
  for (i = 1; i <= np; i++)
    if (lt == PL[i] || substr(lt, 1, length(PL[i]) + 1) == PL[i] "_") return 1
  return 0
}
BEGIN {
  np = split(prefixes, PA, " ")
  for (i = 1; i <= np; i++) PL[i] = tolower(PA[i])
  if (excf != "") while ((getline line < excf) > 0) {
    sub(/#.*/, "", line); n = split(line, f, " ")
    if (n == 0) continue
    if (n != 3) { print "bad exceptions line: " line > "/dev/stderr"; bad = 1; continue }
    ne++; EC[ne] = f[1]; EP[ne] = f[2]; EU[ne] = tolower(f[3])
  }
  if (expf != "") while ((getline line < expf) > 0) {
    sub(/#.*/, "", line); n = split(line, f, " ")
    if (n == 0) continue
    if (n != 2) { print "bad expect-libs line: " line > "/dev/stderr"; bad = 1; continue }
    nx++; XC[nx] = f[1]; XP[nx] = f[2]
  }
  if (bad) exit 2
}
{
  cfg = $1; root = $2; ext = $3; path = $4; raw = $5
  if (!(cfg in seencfg)) { seencfg[cfg] = 1; cfgs[++ncfg] = cfg }
  if (!((cfg SUBSEP root) in seenroot)) { seenroot[cfg SUBSEP root] = 1; if (roots[cfg] == "") roots[cfg] = root; else roots[cfg] = roots[cfg] ", " root }
  if (!((cfg SUBSEP path) in seenpath)) { seenpath[cfg SUBSEP path] = 1; nfile[cfg SUBSEP ext]++ }
  prov = provider(root, path)
  has[cfg SUBSEP prov] = 1
  grp = (ext == "cma" || ext == "cmxa") ? 2 : 1
  top = toupper(substr(raw, 1, 1)) substr(raw, 2)
  i = index(substr(top, 2), "__")
  if (i > 0) top = substr(top, 1, i)
  if (conforming(top)) st = "3-ok"
  else {
    st = "1-VIOLATION"
    for (k = 1; k <= ne; k++)
      if (gm(EC[k], cfg) && gm(EP[k], prov) && gm(EU[k], tolower(top))) { st = "2-EXCEPTED"; used[k] = 1; break }
  }
  key = cfg SUBSEP grp SUBSEP st SUBSEP top SUBSEP prov
  cnt[key]++
  if (index(" " ex[key] " ", " " ext " ") == 0) { if (ex[key] == "") ex[key] = ext; else ex[key] = ex[key] " " ext }
  if (!(key in order)) { order[key] = 1; keys[++nk] = key }
}
END {
  for (c = 1; c <= ncfg; c++) {
    cfg = cfgs[c]
    printf "%s\t0\t%s\t%d\t%d\t%d\t%d\n", cfg, roots[cfg], nfile[cfg SUBSEP "cmi"], nfile[cfg SUBSEP "cmj"], nfile[cfg SUBSEP "cma"], nfile[cfg SUBSEP "cmxa"]
  }
  for (j = 1; j <= nk; j++) {
    split(keys[j], q, SUBSEP)
    printf "%s\t%s\t%s\t%s\t%s\t%d\t%s\n", q[1], q[2], q[3], q[4], q[5], cnt[keys[j]], ex[keys[j]]
  }
  for (k = 1; k <= nx; k++)
    for (c = 1; c <= ncfg; c++)
      if (gm(XC[k], cfgs[c]) && !((cfgs[c] SUBSEP XP[k]) in has))
        printf "%s\t3\tMISSING\t%s\n", cfgs[c], XP[k]
  for (k = 1; k <= ne; k++) {
    if (used[k] || EC[k] == "*") continue
    for (c = 1; c <= ncfg; c++)
      if (gm(EC[k], cfgs[c])) { printf "%s\t4\tUNUSED\t%s %s %s\n", cfgs[c], EC[k], EP[k], EU[k]; break }
  }
}' "$tmp/recs" >"$tmp/rows" || exit 2

# stage 2: report
LC_ALL=C sort -t '	' -k1,1 -k2,2n -k3,3 -k4,4 -k5,5 "$tmp/rows" |
awk -F '\t' -v quiet="$quiet" -v countsf="$tmp/counts" '
function flush(   ) {
  if (cfg == "") return
  printf "  summary: interface units %d (violating %d, excepted %d, ok %d); compiled units %d (violating %d, excepted %d, ok %d)\n",
    n[1], v[1], e[1], o[1], n[2], v[2], e[2], o[2]
}
function reset() { for (g = 1; g <= 2; g++) n[g] = v[g] = e[g] = o[g] = 0 }
BEGIN { reset() }
$1 != cfg {
  flush(); reset(); cfg = $1; hdr[1] = hdr[2] = 0
}
$2 == 0 {
  printf "\n== %s  (%s)\n   files: %d cmi, %d cmj, %d cma, %d cmxa\n", $1, $3, $4, $5, $6, $7
  next
}
$2 == 1 || $2 == 2 {
  g = $2
  if (!hdr[g]) {
    hdr[g] = 1
    print (g == 1 ? "  interfaces (.cmi/.cmj), __X stripped:" : "  compiled units (ocamlobjinfo .cma/.cmxa), __X stripped:")
  }
  n[g]++
  if ($3 == "1-VIOLATION") { v[g]++; tag = "VIOLATION"; tv++ }
  else if ($3 == "2-EXCEPTED") { e[g]++; tag = "EXCEPTED " }
  else { o[g]++; tag = "ok       " }
  if (tag == "ok       " && quiet) next
  printf "    %s %-28s provider=%s  x%d (%s)\n", tag, $4, $5, $6, $7
  next
}
$2 == 3 { printf "  MISSING library: %s\n", $4; tm++; next }
$2 == 4 { printf "  warning: unused exception: %s\n", $4; next }
END { flush(); printf "\nRESULT: %d violation(s), %d missing librar%s\n", tv, tm, (tm == 1 ? "y" : "ies"); print tv + tm > countsf }
'
nfind=$(cat "$tmp/counts" 2>/dev/null || echo 0)
if [ "$fail" -eq 1 ] && [ "$nfind" -gt 0 ]; then exit 1; fi
exit 0
