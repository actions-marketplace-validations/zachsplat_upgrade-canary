# Runs inside the image under test, under the static busybox that canary.sh
# copies to /.canary, so it also works in images that have no shell.
#
# usage: /.canary/busybox sh /.canary/inspect.sh MODES EXCLUDE_REGEX PATH...
#   MODES  comma list: elf (shared-library check), pkg (package database)
#
# Output, one tab-separated record per line:
#   LOADER <glibc|musl> <path>
#   ELF <status> <file> <detail>
#     missing      an executable has libraries or symbol versions the loader cannot find
#     nointerp     an executable names an interpreter (dynamic loader) the image does not have
#     libmissing   a shared object (library, plugin, extension module) has unresolved libraries
#     foreign      a shared object built for the other C library (musl in a glibc image or back)
#     noloader     a dynamic shared object in an image with no dynamic loader
#     unchecked    the loader could not list it; detail is its first output line
#     ok, static, object, otherarch
#   PKG <deb|apk|rpm> <name> <version>
#   DONE <elf files seen>

BB=/.canary/busybox
modes=$1
excl=$2
shift 2
[ $# -eq 0 ] && set -- /
T=$(printf '\t')
MAGIC=$(printf '\177ELF')

oneline() {
	printf '%s\n' "$1" | $BB head -n 1 | $BB tr '\t' ' ' | $BB cut -c 1-200
}

find_loaders() {
	arch=$($BB uname -m)
	case $arch in
		x86_64) gl=ld-linux-x86-64.so.2; ml=ld-musl-x86_64.so.1; HOST_MACHINE=62 ;;
		aarch64) gl=ld-linux-aarch64.so.1; ml=ld-musl-aarch64.so.1; HOST_MACHINE=183 ;;
		armv7l|armv6l) gl=ld-linux-armhf.so.3; ml=ld-musl-armhf.so.1; HOST_MACHINE=40 ;;
		ppc64le) gl=ld64.so.2; ml=ld-musl-powerpc64le.so.1; HOST_MACHINE=21 ;;
		riscv64) gl=ld-linux-riscv64-lp64d.so.1; ml=ld-musl-riscv64.so.1; HOST_MACHINE=243 ;;
		i686|i386) gl=ld-linux.so.2; ml=ld-musl-i386.so.1; HOST_MACHINE=3 ;;
		*) gl=none; ml=none; HOST_MACHINE= ;;
	esac
	GLIBC_LD=
	MUSL_LD=
	for d in /lib64 /lib /usr/lib64 /usr/lib /lib/$arch-linux-gnu /usr/lib/$arch-linux-gnu; do
		[ -z "$GLIBC_LD" ] && [ -e "$d/$gl" ] && GLIBC_LD=$d/$gl
		[ -z "$MUSL_LD" ] && [ -e "$d/$ml" ] && MUSL_LD=$d/$ml
	done
	[ -n "$GLIBC_LD" ] && echo "LOADER${T}glibc${T}$GLIBC_LD"
	[ -n "$MUSL_LD" ] && echo "LOADER${T}musl${T}$MUSL_LD"
	DEFAULT_LD=${GLIBC_LD:-$MUSL_LD}
}

# Reads the ELF header and program headers of $1 (little-endian only) and sets
# E_TYPE, E_MACHINE, E_DYNAMIC (0 or 1) and E_INTERP (PT_INTERP path or empty).
read_elf() {
	f=$1
	E_DYNAMIC=0
	E_INTERP=
	set -- $($BB od -An -v -tu1 -N 64 "$f" 2>/dev/null)
	[ $# -ge 52 ] || return 1
	cls=$5
	[ "$6" = 1 ] || return 1
	E_TYPE=$((${17} + ${18} * 256))
	E_MACHINE=$((${19} + ${20} * 256))
	if [ "$cls" = 2 ]; then
		[ $# -ge 64 ] || return 1
		phoff=$((${33} + ${34} * 256 + ${35} * 65536 + ${36} * 16777216))
		phentsize=$((${55} + ${56} * 256))
		phnum=$((${57} + ${58} * 256))
	else
		phoff=$((${29} + ${30} * 256 + ${31} * 65536 + ${32} * 16777216))
		phentsize=$((${43} + ${44} * 256))
		phnum=$((${45} + ${46} * 256))
	fi
	[ "$phnum" -gt 0 ] && [ "$phnum" -lt 512 ] && [ "$phentsize" -ge 32 ] || return 0
	total=$((phnum * phentsize))
	set -- $($BB od -An -v -tu1 -j "$phoff" -N "$total" "$f" 2>/dev/null)
	[ $# -ge "$total" ] || return 0
	i=0
	ioff=
	isz=0
	while [ "$i" -lt "$phnum" ]; do
		b=$((i * phentsize))
		eval "pt=\$((\${$((b + 1))} + \${$((b + 2))} * 256 + \${$((b + 3))} * 65536 + \${$((b + 4))} * 16777216))"
		if [ "$pt" = 2 ]; then
			E_DYNAMIC=1
		elif [ "$pt" = 3 ]; then
			if [ "$cls" = 2 ]; then
				eval "ioff=\$((\${$((b + 9))} + \${$((b + 10))} * 256 + \${$((b + 11))} * 65536 + \${$((b + 12))} * 16777216))"
				eval "isz=\$((\${$((b + 33))} + \${$((b + 34))} * 256))"
			else
				eval "ioff=\$((\${$((b + 5))} + \${$((b + 6))} * 256 + \${$((b + 7))} * 65536 + \${$((b + 8))} * 16777216))"
				eval "isz=\$((\${$((b + 17))} + \${$((b + 18))} * 256))"
			fi
		fi
		i=$((i + 1))
	done
	if [ -n "$ioff" ] && [ "$isz" -gt 1 ] && [ "$isz" -lt 4096 ]; then
		E_INTERP=$($BB dd if="$f" bs=1 skip="$ioff" count=$((isz - 1)) 2>/dev/null)
	fi
	return 0
}

# Library names the loader could not resolve, from glibc trace output or musl
# --list output. Missing symbols are only counted when no library is missing.
missing_names() {
	printf '%s\n' "$1" | $BB awk '
		function add(n) { if (n != "" && !(n in seen)) { seen[n] = 1; out = out (out == "" ? "" : " ") n } }
		/ => not found/ { add($1); next }
		/version .* not found/ {
			lib = ""; v = ""
			for (i = 2; i < NF; i++) if ($i == "version") { v = $(i + 1); lib = $(i - 1) }
			gsub(/[`'"'"'"]/, "", v); sub(/:$/, "", lib); sub(/.*\//, "", lib)
			add(lib "(" v ")"); next
		}
		/error while loading shared libraries: .*: cannot open shared object file/ {
			s = $0; sub(/.*error while loading shared libraries: /, "", s); sub(/: cannot open shared object file.*/, "", s)
			add(s); next
		}
		/^Error loading shared library / { n = $5; sub(/:$/, "", n); add(n); next }
		/^Error relocating / && /symbol not found/ { syms++ }
		END {
			if (syms && out == "") add("missing-symbols:" syms)
			print out
		}'
}

# True when every missing name belongs to the other C library.
only_other_libc() {
	others=$(printf '%s\n' $1 | $BB grep -vE "$2")
	[ -z "$others" ]
}

check_elf() {
	f=$1
	if ! read_elf "$f"; then
		echo "ELF${T}unchecked${T}$f${T}not a little-endian ELF file this check can read"
		return
	fi
	case $E_TYPE in
		2|3) ;;
		*) echo "ELF${T}object${T}$f${T}type $E_TYPE"; return ;;
	esac
	if [ -n "$HOST_MACHINE" ] && [ "$E_MACHINE" != "$HOST_MACHINE" ]; then
		echo "ELF${T}otherarch${T}$f${T}machine $E_MACHINE"
		return
	fi
	if [ "$E_DYNAMIC" = 0 ]; then
		echo "ELF${T}static${T}$f${T}-"
		return
	fi
	if [ -n "$E_INTERP" ]; then
		if [ ! -e "$E_INTERP" ]; then
			echo "ELF${T}nointerp${T}$f${T}$E_INTERP"
			return
		fi
		ld=$E_INTERP
	else
		ld=$DEFAULT_LD
		if [ -z "$ld" ]; then
			echo "ELF${T}noloader${T}$f${T}-"
			return
		fi
	fi
	case $ld in
		*ld-musl*) out=$("$ld" --list "$f" 2>&1); rc=$? ;;
		*) out=$(LD_TRACE_LOADED_OBJECTS=1 "$ld" "$f" 2>&1); rc=$? ;;
	esac
	miss=$(missing_names "$out")
	if [ -n "$miss" ]; then
		if [ -n "$E_INTERP" ]; then
			status=missing
		else
			status=libmissing
			case $ld in
				*ld-musl*) only_other_libc "$miss" '^(ld-linux.*|ld64\.so\..*|libc\.so\.6|libm\.so\.6|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1|libresolv\.so\.2|libutil\.so\.1|libgcc_s\.so\.1)$' && status=foreign ;;
				*) only_other_libc "$miss" '^(libc\.musl-.*|ld-musl-.*|libc\.so)$' && status=foreign ;;
			esac
		fi
		echo "ELF${T}${status}${T}$f${T}$miss"
	elif [ "$rc" -eq 0 ]; then
		echo "ELF${T}ok${T}$f${T}-"
	else
		echo "ELF${T}unchecked${T}$f${T}exit $rc: $(oneline "$out")"
	fi
}

elf_scan() {
	find_loaders
	$BB find "$@" -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /.canary -o -path /usr/lib/debug \) -prune -o -type f -size +0 -print 2>/dev/null |
		if [ -n "$excl" ]; then $BB grep -Ev -- "$excl"; else $BB cat; fi |
		{
			n=0
			while IFS= read -r f; do
				m=
				IFS= read -r -n 4 m < "$f" 2>/dev/null
				[ "$m" = "$MAGIC" ] || continue
				n=$((n + 1))
				check_elf "$f"
			done
			echo "DONE${T}$n"
		}
}

pkg_db() {
	for st in /var/lib/dpkg/status /var/lib/dpkg/status.d/*; do
		[ -f "$st" ] || continue
		$BB awk -v T="$T" '
			function emit() { if (p != "" && ok) print "PKG" T "deb" T p T v; p = "" }
			/^Package: / { emit(); p = $2; v = ""; ok = 1 }
			/^Status: / { ok = ($0 ~ / installed$/) }
			/^Version: / { v = $2 }
			/^$/ { emit() }
			END { emit() }' "$st"
	done
	for db in /lib/apk/db/installed /usr/lib/apk/db/installed; do
		[ -f "$db" ] || continue
		$BB awk -v T="$T" '
			function emit() { if (p != "") print "PKG" T "apk" T p T v; p = "" }
			/^P:/ { p = substr($0, 3) }
			/^V:/ { v = substr($0, 3) }
			/^$/ { emit() }
			END { emit() }' "$db"
		break
	done
	for rpm in /usr/bin/rpm /bin/rpm; do
		[ -x "$rpm" ] || continue
		"$rpm" -qa --qf "PKG${T}rpm${T}%{NAME}${T}%{VERSION}-%{RELEASE}\n" 2>/dev/null
		break
	done
}

case ",$modes," in *,elf,*) elf_scan "$@" ;; esac
case ",$modes," in *,pkg,*) pkg_db ;; esac
exit 0
