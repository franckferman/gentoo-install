# Is any function reachable from inside a command substitution able to install a
# trap — directly, or through the functions it calls?
#
# Looking only for a literal `trap` in the substituted function is not enough,
# and that gap is the whole lesson. crypt_secret_file() ran in "$( )" and called
# crypt_arm_secret_trap(), which held the trap command. A trap installed inside
# a subshell fires when that subshell ends; this one called cleanup(), which
# unmounts every tracked mount. So creating a secret file unmounted the machine
# being installed, and the next line failed about a path that had just existed.
#
# Input: every shell file in the project. Output: one offending function per
# line, with the armer it reaches.
/^[a-zA-Z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ {
  fn = $0
  sub(/\(\).*/, "", fn)
  next
}
{
  line = $0
  sub(/#.*/, "", line)

  # Who is called inside a command substitution, anywhere in the project.
  rest = line
  while (match(rest, /\$\([a-z_][A-Za-z0-9_]*/)) {
    name = substr(rest, RSTART + 2, RLENGTH - 2)
    substituted[name] = 1
    rest = substr(rest, RSTART + RLENGTH)
  }

  if (fn == "") next
  if (line ~ /^[[:space:]]*trap[[:space:]]+[^[:space:]]/) arms[fn] = fn
  n = split(line, w, /[^A-Za-z0-9_]+/)
  for (i = 1; i <= n; i++) if (w[i] != "" && w[i] != fn) calls[fn, w[i]] = 1
}
END {
  changed = 1
  while (changed) {
    changed = 0
    for (k in calls) {
      split(k, p, SUBSEP)
      if ((p[2] in arms) && !(p[1] in arms)) { arms[p[1]] = arms[p[2]]; changed = 1 }
    }
  }
  for (f in substituted) if (f in arms) printf "%s reaches %s\n", f, arms[f]
}
