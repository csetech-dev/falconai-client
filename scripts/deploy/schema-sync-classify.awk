# Classify the SQL printed by
#   prisma migrate diff --from-schema-datasource S --to-schema-datamodel S --script
# into what the guarded schema sync (scripts/deploy/schema-sync.sh) may apply.
#
#   awk -v keeplist=scripts/performance/live-only-indexes.txt -v outdir=DIR \
#       -f scripts/deploy/schema-sync-classify.awk < diff.sql
#
# POSIX awk only (gawk, mawk, busybox): the deploy host runs it, and Ubuntu's
# default awk is mawk. No gensub, IGNORECASE, \y or match() arrays.
#
# The input is split into statements on top-level semicolons. Comments
# (-- and nested /* */) are dropped; '...' (incl. E'...'), "..." and
# $tag$...$tag$ are kept verbatim and never split. Each statement is then
# matched on its "skeleton" (literals -> 'S', quoted identifiers -> "I",
# upper-cased, whitespace collapsed), so a keyword inside a name or a default
# value can never change the verdict.
#
# Allow-list, NOT deny-list: anything not recognised below is BLOCKED.
#   ALLOW  CREATE [UNIQUE] INDEX | CREATE TABLE | CREATE TYPE |
#          CREATE EXTENSION | CREATE SCHEMA | CREATE SEQUENCE
#   ALLOW  ALTER TABLE t <actions> when EVERY comma-separated action is
#          ADD ... (COLUMN / CONSTRAINT / FOREIGN KEY ...) |
#          ALTER [COLUMN] c DROP NOT NULL | ALTER [COLUMN] c SET DEFAULT ...
#   ENUM   ALTER TYPE t ADD VALUE ...   (applied first, outside the transaction)
#   SKIP   DROP INDEX of names that are ALL on the keep-list (no CASCADE)
#   CTRL   BEGIN / COMMIT (Prisma wraps enum rewrites in them; the sync runs
#          its own single transaction, and the rewrite itself is blocked)
#   BLOCK  everything else: DROP COLUMN/TABLE/TYPE/CONSTRAINT, other DROP
#          INDEX, ALTER COLUMN TYPE / SET NOT NULL / DROP DEFAULT, RENAME, ...
#
# Files written to outdir (always created, possibly empty):
#   enum.sql      ALTER TYPE ... ADD VALUE statements
#   apply.sql     allowed statements, original order
#   defer.sql     allowed statements + the allowed actions of a partly blocked
#                 ALTER TABLE, original order (FALCON_SCHEMA_SYNC_DEFER_DESTRUCTIVE=1)
#   override.sql  every statement except skipped/enum/control, original order
#                 (FALCON_ALLOW_DESTRUCTIVE_SCHEMA=1)
#   blocked.sql   blocked statements, verbatim
#   skipped.txt   keep-listed index names whose DROP was skipped
# stdout: one line per verdict plus a SUMMARY line.
# Exit: 0 nothing blocked, 3 something blocked, 2 parse/usage error.

function fail(msg) {
  print "schema-sync-classify: ERROR: " msg > "/dev/stderr"
  fatal = 1
}

function trim(s) {
  gsub(/^[ \t\n]+/, "", s)
  gsub(/[ \t\n]+$/, "", s)
  return s
}

function oneline(s, max) {
  gsub(/[ \t\n]+/, " ", s)
  s = trim(s)
  if (max > 0 && length(s) > max) s = substr(s, 1, max) "..."
  return s
}

# End index of the '...' / "..." token that starts at s[i] (0 = unterminated).
# Doubled quotes are escapes; E'...' strings also honour backslash escapes.
function qend(s, i, n,   q, j, d, esc) {
  q = substr(s, i, 1)
  esc = (q == "'" && i > 1 && substr(s, i - 1, 1) ~ /[Ee]/ && (i == 2 || substr(s, i - 2, 1) !~ /[A-Za-z0-9_$]/))
  j = i + 1
  while (j <= n) {
    d = substr(s, j, 1)
    if (esc && d == "\\") { j += 2; continue }
    if (d == q) {
      if (substr(s, j + 1, 1) == q) { j += 2; continue }
      return j
    }
    j++
  }
  return 0
}

# End index of the $tag$...$tag$ token at s[i]; 0 = not a dollar quote here,
# -1 = unterminated.
function dqend(s, i, n,   rest, tl, tag, k) {
  if (i > 1 && substr(s, i - 1, 1) ~ /[A-Za-z0-9_]/) return 0
  rest = substr(s, i, 66)
  if (!match(rest, /^\$([A-Za-z_][A-Za-z0-9_]*)?\$/)) return 0
  tl = RLENGTH
  tag = substr(rest, 1, tl)
  k = index(substr(s, i + tl), tag)
  if (k == 0) return -1
  return i + tl + k - 1 + tl - 1
}

# Upper-cased skeleton of one statement or action.
function mkskel(s,   out, n, i, c, j) {
  out = ""
  n = length(s)
  i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "'" || c == "\"") {
      j = qend(s, i, n)
      if (j == 0) j = n
      out = out (c == "'" ? "'S'" : "\"I\"")
      i = j + 1
      continue
    }
    if (c == "$") {
      j = dqend(s, i, n)
      if (j > 0) { out = out "$B$"; i = j + 1; continue }
    }
    out = out c
    i++
  }
  return oneline(toupper(out), 0)
}

# Split s on top-level commas (outside quotes and parentheses) into arr[1..k].
function split_top(s, arr,   n, i, c, j, depth, k, start) {
  n = length(s)
  k = 0
  depth = 0
  start = 1
  i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "'" || c == "\"") {
      j = qend(s, i, n)
      if (j == 0) j = n
      i = j + 1
      continue
    }
    if (c == "$") {
      j = dqend(s, i, n)
      if (j > 0) { i = j + 1; continue }
    }
    if (c == "(") depth++
    else if (c == ")") depth--
    else if (c == "," && depth == 0) {
      arr[++k] = trim(substr(s, start, i - start))
      start = i + 1
    }
    i++
  }
  arr[++k] = trim(substr(s, start))
  return k
}

# Bare index name from  "x" | x | "schema"."x" | schema.x  ("" if unparseable).
# Unquoted names fold to lower case, as PostgreSQL does.
function idxname(s,   L, e, part) {
  s = trim(s)
  while (1) {
    L = length(s)
    if (L == 0) return ""
    if (substr(s, 1, 1) == "\"") {
      e = qend(s, 1, L)
      if (e == 0) return ""
      part = substr(s, 2, e - 2)
      gsub(/""/, "\"", part)
    } else {
      if (!match(s, /^[A-Za-z_][A-Za-z0-9_$]*/)) return ""
      e = RLENGTH
      part = tolower(substr(s, 1, e))
    }
    if (e == L) return part
    if (substr(s, e + 1, 1) != ".") return ""
    s = substr(s, e + 2)
  }
}

function addstmt(t) {
  t = trim(t)
  if (t != "") st[++nst] = t
}

function emit(file, t) {
  printf "%s;\n\n", t > (outdir "/" file)
}

function allow(t) {
  emit("apply.sql", t)
  emit("defer.sql", t)
  emit("override.sql", t)
  nallow++
  print "ALLOW    " oneline(t, 200)
}

function block(t, why) {
  emit("blocked.sql", t)
  emit("override.sql", t)
  nblock++
  print "BLOCK    " why ": " oneline(t, 300)
}

function classify_alter_table(t,   hl, rest, header, body, na, acts, x, ka, good, bad, nb, ng) {
  if (!match(t, /^[Aa][Ll][Tt][Ee][Rr][ \t\n]+[Tt][Aa][Bb][Ll][Ee][ \t\n]+/)) { block(t, "unparsed ALTER TABLE"); return }
  hl = RLENGTH
  rest = substr(t, hl + 1)
  if (match(rest, /^[Ii][Ff][ \t\n]+[Ee][Xx][Ii][Ss][Tt][Ss][ \t\n]+/)) { hl += RLENGTH; rest = substr(rest, RLENGTH + 1) }
  if (match(rest, /^[Oo][Nn][Ll][Yy][ \t\n]+/)) { hl += RLENGTH; rest = substr(rest, RLENGTH + 1) }
  if (!match(rest, /^("([^"]|"")*"|[A-Za-z_][A-Za-z0-9_$]*)(\.("([^"]|"")*"|[A-Za-z_][A-Za-z0-9_$]*))?[ \t\n]+/)) {
    block(t, "unparsed ALTER TABLE target")
    return
  }
  hl += RLENGTH
  header = substr(t, 1, hl)
  body = substr(t, hl + 1)
  na = split_top(body, acts)
  good = ""
  bad = ""
  ng = 0
  nb = 0
  for (x = 1; x <= na; x++) {
    ka = mkskel(acts[x])
    if (ka ~ /^ADD / || ka ~ /^ALTER (COLUMN )?[^ ]+ DROP NOT NULL$/ || ka ~ /^ALTER (COLUMN )?[^ ]+ SET DEFAULT /) {
      good = good (ng++ ? ",\n" : "") acts[x]
    } else {
      bad = bad (nb++ ? "; " : "") oneline(acts[x], 120)
    }
  }
  if (nb == 0) { allow(t); return }
  block(t, "ALTER TABLE action not additive [" bad "]")
  if (ng > 0) {
    emit("defer.sql", trim(header) "\n" good)
    print "PARTIAL  deferrable additive part: " oneline(trim(header) " " good, 200)
  }
}

function classify_drop_index(t,   rest, n, names, x, nm, all, list) {
  rest = t
  sub(/^[Dd][Rr][Oo][Pp][ \t\n]+[Ii][Nn][Dd][Ee][Xx][ \t\n]+/, "", rest)
  if (match(rest, /^[Cc][Oo][Nn][Cc][Uu][Rr][Rr][Ee][Nn][Tt][Ll][Yy][ \t\n]+/)) rest = substr(rest, RLENGTH + 1)
  if (match(rest, /^[Ii][Ff][ \t\n]+[Ee][Xx][Ii][Ss][Tt][Ss][ \t\n]+/)) rest = substr(rest, RLENGTH + 1)
  if (rest ~ /[ \t\n][Cc][Aa][Ss][Cc][Aa][Dd][Ee]$/) { block(t, "DROP INDEX ... CASCADE"); return }
  sub(/[ \t\n]+[Rr][Ee][Ss][Tt][Rr][Ii][Cc][Tt]$/, "", rest)
  n = split_top(rest, names)
  all = 1
  list = ""
  for (x = 1; x <= n; x++) {
    nm = idxname(names[x])
    if (nm == "" || !(nm in keep)) all = 0
    list = list (x > 1 ? ", " : "") (nm == "" ? names[x] : nm)
  }
  if (!all) { block(t, "DROP INDEX not on the keep-list (" list ")"); return }
  for (x = 1; x <= n; x++) {
    nm = idxname(names[x])
    print nm > (outdir "/skipped.txt")
    nskip++
    print "SKIP     keep-listed index, DROP skipped: " nm
  }
}

BEGIN {
  fatal = 0
  if (outdir == "") { fail("outdir is not set (-v outdir=DIR)") }
  if (keeplist == "") { fail("keeplist is not set (-v keeplist=FILE)") }
  if (!fatal) {
    nkeep = 0
    while ((rc = (getline line < keeplist)) > 0) {
      sub(/\r$/, "", line)
      sub(/#.*/, "", line)
      line = trim(line)
      if (line != "") { keep[line] = 1; nkeep++ }
    }
    if (rc < 0) fail("cannot read keep-list " keeplist)
    else close(keeplist)
    if (!fatal && nkeep == 0) fail("keep-list " keeplist " is empty")
  }
  buf = ""
}

{
  sub(/\r$/, "")
  buf = buf $0 "\n"
}

END {
  if (fatal) exit 2
  # Create every output file, so callers can test -s without -e.
  split("enum.sql apply.sql defer.sql override.sql blocked.sql skipped.txt", outs, " ")
  for (x = 1; x <= 6; x++) { printf "" > (outdir "/" outs[x]) }

  n = length(buf)
  i = 1
  cur = ""
  nst = 0
  while (i <= n) {
    if (match(substr(buf, i, 4096), /^[^-\/'"$;]+/)) {
      cur = cur substr(buf, i, RLENGTH)
      i += RLENGTH
      continue
    }
    c = substr(buf, i, 1)
    c2 = substr(buf, i, 2)
    if (c2 == "--") {
      j = index(substr(buf, i), "\n")
      if (j == 0) i = n + 1
      else i += j - 1
      cur = cur " "
      continue
    }
    if (c2 == "/*") {
      depth = 1
      j = i + 2
      while (j <= n && depth > 0) {
        t2 = substr(buf, j, 2)
        if (t2 == "/*") { depth++; j += 2 }
        else if (t2 == "*/") { depth--; j += 2 }
        else j++
      }
      if (depth > 0) { fail("unterminated /* comment"); break }
      cur = cur " "
      i = j
      continue
    }
    if (c == "'" || c == "\"") {
      j = qend(buf, i, n)
      if (j == 0) { fail("unterminated " c " quote"); break }
      cur = cur substr(buf, i, j - i + 1)
      i = j + 1
      continue
    }
    if (c == "$") {
      j = dqend(buf, i, n)
      if (j < 0) { fail("unterminated dollar quote"); break }
      if (j > 0) {
        cur = cur substr(buf, i, j - i + 1)
        i = j + 1
        continue
      }
    }
    if (c == ";") {
      addstmt(cur)
      cur = ""
      i++
      continue
    }
    cur = cur c
    i++
  }
  if (fatal) exit 2
  addstmt(cur)

  nallow = 0; nenum = 0; nskip = 0; nblock = 0; nctrl = 0
  for (s = 1; s <= nst; s++) {
    t = st[s]
    k = mkskel(t)
    if (k ~ /^(BEGIN|COMMIT|END|START TRANSACTION)( TRANSACTION| WORK)?$/) {
      nctrl++
      print "CTRL     " k " (the sync runs its own transaction)"
    } else if (k ~ /^CREATE (UNIQUE )?INDEX / || k ~ /^CREATE (TABLE|TYPE|EXTENSION|SCHEMA|SEQUENCE) /) {
      allow(t)
    } else if (k ~ /^ALTER TYPE [^ ]+ ADD VALUE /) {
      emit("enum.sql", t)
      nenum++
      print "ENUM     " oneline(t, 200)
    } else if (k ~ /^ALTER TABLE /) {
      classify_alter_table(t)
    } else if (k ~ /^DROP INDEX /) {
      classify_drop_index(t)
    } else {
      block(t, "not on the additive allow-list")
    }
  }
  for (x = 1; x <= 6; x++) close(outdir "/" outs[x])
  printf "SUMMARY  statements=%d allowed=%d enum=%d skipped=%d blocked=%d control=%d\n", nst, nallow, nenum, nskip, nblock, nctrl
  exit (nblock > 0 ? 3 : 0)
}
