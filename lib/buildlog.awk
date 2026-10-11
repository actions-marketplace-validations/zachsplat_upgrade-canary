# Reads a BuildKit plain progress log and prints what the build pulled in:
#   base  <stage> image <ref> <digest>     for each FROM
#   build <stage> apk|deb|python <name> <version>
# for packages that apk, apt (dpkg) and pip report while installing.
BEGIN { OFS = "\t" }

function emit(scope, stg, type, name, ver) {
	k = scope SUBSEP stg SUBSEP type SUBSEP name SUBSEP ver
	if (k in seen) return
	seen[k] = 1
	print scope, stg, type, name, ver
}

/^#[0-9]+ \[/ {
	id = $1
	s = $0
	sub(/^#[0-9]+ \[/, "", s)
	inside = s
	sub(/\].*/, "", inside)
	rest = substr(s, length(inside) + 3)
	n = split(inside, w, " ")
	stg = (n >= 2) ? w[1] : ""
	if (stg == "internal") next
	stage[id] = stg
	if (rest ~ /^FROM /) {
		ref = rest
		sub(/^FROM /, "", ref)
		sub(/ .*/, "", ref)
		name = ref
		dig = ""
		if (index(ref, "@")) {
			name = substr(ref, 1, index(ref, "@") - 1)
			dig = substr(ref, index(ref, "@") + 1)
		}
		emit("base", stg, "image", name, dig)
	}
	next
}

/^#[0-9]+ [0-9]+\.[0-9]+ / {
	id = $1
	t = $0
	sub(/^#[0-9]+ [0-9]+\.[0-9]+ /, "", t)
	stg = (id in stage) ? stage[id] : ""
	if (t ~ /^\([0-9]+\/[0-9]+\) Installing [^ ]+ \(/) {
		split(t, a, " ")
		v = t
		sub(/^[^(]*\([0-9]+\/[0-9]+\) Installing [^ ]+ \(/, "", v)
		sub(/\).*/, "", v)
		emit("build", stg, "apk", a[3], v)
	} else if (t ~ /^\([0-9]+\/[0-9]+\) Upgrading [^ ]+ \(/) {
		split(t, a, " ")
		v = t
		sub(/.*-> /, "", v)
		sub(/\).*/, "", v)
		emit("build", stg, "apk", a[3], v)
	} else if (t ~ /^Setting up [^ ]+ \(/) {
		split(t, a, " ")
		name = a[3]
		sub(/:[a-z0-9_]+$/, "", name)
		v = t
		sub(/^Setting up [^ ]+ \(/, "", v)
		sub(/\).*/, "", v)
		emit("build", stg, "deb", name, v)
	} else if (t ~ /^Successfully installed /) {
		sub(/^Successfully installed /, "", t)
		m = split(t, pk, " ")
		for (i = 1; i <= m; i++) {
			p = pk[i]
			j = match(p, /-[^-]+$/)
			if (j > 1) emit("build", stg, "python", substr(p, 1, j - 1), substr(p, j + 1))
		}
	}
}
