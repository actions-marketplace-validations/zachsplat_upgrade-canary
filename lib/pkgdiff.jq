# Compares two package lists written by canary.sh.
# usage: jq -n --slurpfile old OLD.json --slurpfile new NEW.json -f pkgdiff.jq
#
# Packages are matched by scope, stage, type and a family name that drops
# version numbers from the package name, so that openssl-3.6-dev and
# openssl-4.0-dev, or libssl3 and libssl3t64, count as one package that changed.

def family:
  ascii_downcase
  | sub(":[a-z0-9_]+$"; "")
  | sub("t64$"; "")
  | split("-")
  | map(select(test("^[0-9]+([.][0-9]+)*$") | not) | sub("(?<=[a-z+])[0-9]+([.][0-9]+)*$"; ""))
  | map(select(. != ""))
  | join("-");

def fam: .family // (.name | family);
def key: [.scope, (.stage // ""), .type, fam] | join("|");
def grouped: map({k: key, v: .}) | group_by(.k)
  | map({key: .[0].k, value: (map(.v) | unique_by([.name, .version]))}) | from_entries;
def names: map(.name + " " + .version) | join(", ");
def scope_rank: {"base": 0, "build": 1, "runtime": 2}[.] // 3;
def type_rank: if . == "image" then 0 elif (. == "apk" or . == "deb" or . == "rpm") then 1 elif . == "binary" then 2 else 3 end;
def change_rank: {"changed": 0, "added": 1, "removed": 2}[.];

(($old[0].packages) // []) as $o
| (($new[0].packages) // []) as $n
| ($o | grouped) as $O
| ($n | grouped) as $N
| ([($O | keys), ($N | keys)] | add | unique) as $keys
| [ $keys[] as $k
    | ($O[$k] // []) as $a
    | ($N[$k] // []) as $b
    | select(($a | map([.name, .version])) != ($b | map([.name, .version])))
    | (($a + $b)[0]) as $p
    | {
        scope: $p.scope,
        stage: ($p.stage // ""),
        type: $p.type,
        family: ($p | fam),
        change: (if ($a | length) == 0 then "added" elif ($b | length) == 0 then "removed" else "changed" end),
        before: ($a | names),
        after: ($b | names)
      } ]
| sort_by([(.scope | scope_rank), (.type | type_rank), (.change | change_rank), .stage, .family])
| {
    old: {run: ($old[0].run // ""), image: ($old[0].image // ""), digest: ($old[0].digest // "")},
    new: {run: ($new[0].run // ""), image: ($new[0].image // ""), digest: ($new[0].digest // "")},
    counts: {
      changed: (map(select(.change == "changed")) | length),
      added: (map(select(.change == "added")) | length),
      removed: (map(select(.change == "removed")) | length)
    },
    changes: .
  }
