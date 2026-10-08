#!/bin/bash
#
# Tests for entrypoint.sh. Plain bash against throwaway git repos -- no framework, so it runs
# anywhere the action itself runs.
#
#   ./test/entrypoint_test.sh
#
# Every case pins the clock with --forced_date. Without that the expected versions would
# depend on the week the suite happens to run in, which is exactly the kind of silent drift
# these tests exist to catch.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ENTRYPOINT="$HERE/../entrypoint.sh"
WORKROOT=$(mktemp -d)
PASS=0
FAIL=0

# `date -d` is GNU-only. On a BSD userland (macOS) fall back to gdate via a PATH shim so the
# suite is runnable on a laptop as well as in the Debian-based action image.
if ! date --version >/dev/null 2>&1; then
    if command -v gdate >/dev/null 2>&1; then
        mkdir -p "$WORKROOT/shim"
        printf '#!/bin/sh\nexec gdate "$@"\n' > "$WORKROOT/shim/date"
        chmod +x "$WORKROOT/shim/date"
        PATH="$WORKROOT/shim:$PATH"
        export PATH
    else
        echo "SKIP: no GNU date (install coreutils for gdate); --forced_date cases need it." >&2
        exit 0
    fi
fi

cleanup() { rm -rf "$WORKROOT"; }
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }

check() {  # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}

# Build a repo + bare remote. Extra args are tag specs: "name" (lightweight) or "name:a"
# (annotated). Each tag lands on its own commit, in the order given.
make_repo() {
    local name=$1; shift
    local dir="$WORKROOT/$name"
    mkdir -p "$dir" && cd "$dir"
    git init -q --bare remote.git
    git init -q -b master work && cd work
    git config user.email t@t.t && git config user.name t
    echo '{ "headVersion": "2" }' > package.json
    git add . && git commit -qm init
    git remote add origin ../remote.git
    for spec in "$@"; do
        echo "$spec" >> log.txt && git add -A && git commit -qm "$spec"
        case "$spec" in
            *:a) git tag -a "${spec%:a}" -m "release ${spec%:a}" ;;
            *)   git tag "$spec" ;;
        esac
    done
    git push -q origin master --tags 2>/dev/null
    echo "$dir/work"
}

remote_tags() { git ls-remote --tags origin 2>/dev/null | sed 's#.*refs/tags/##' | grep -v '\^{}' | sort -V | tr '\n' ' ' | sed 's/ $//'; }

echo "entrypoint.sh"

# ---------------------------------------------------------------------------------------
# 1. The regression itself: one ANNOTATED tag among lightweight ones.
#    `--sort=committerdate` floats the annotated tag to position 1 (it has no committerdate),
#    so `tail -1` returned 2.2641.0 and every run recomputed the already-taken 2.2641.1.
# ---------------------------------------------------------------------------------------
# The annotated tag must be the HIGHEST version here -- that is what mediacat looked like
# before the wedge was broken by hand. With a lightweight tag above it, floating the annotated
# one to the front still leaves `tail -1` on the right answer, and the bug hides.
cd "$(make_repo annotated 2.2640.4 2.2641.0 2.2641.1:a)"
out=$(bash "$ENTRYPOINT" --forced_date=2026-10-08 2>&1); rc=$?
check "annotated tag does not hide the latest" "latest 2.2641.1" "$(echo "$out" | grep '^latest ')"
check "computes the next build, not a taken one" "version: 2.2641.2" "$(echo "$out" | grep '^version:')"
check "  exits 0" "0" "$rc"
check "  pushes the new tag" "2.2640.4 2.2641.0 2.2641.1 2.2641.2" "$(remote_tags)"

# ---------------------------------------------------------------------------------------
# 2. Numeric ordering: .10 is newer than .9. A lexical sort disagrees.
# ---------------------------------------------------------------------------------------
cd "$(make_repo numeric 2.2641.8 2.2641.9 2.2641.10)"
out=$(bash "$ENTRYPOINT" --forced_date=2026-10-08 2>&1)
check "orders .10 after .9" "latest 2.2641.10" "$(echo "$out" | grep '^latest ')"
check "  next build follows .10" "version: 2.2641.11" "$(echo "$out" | grep '^version:')"

# ---------------------------------------------------------------------------------------
# 3. Collision guard: refuse to report success without tagging. This is the defect that hid
#    the one above -- `git tag` failed, `git push` ran last, and the step went green.
# ---------------------------------------------------------------------------------------
cd "$(make_repo collision 2.2641.0)"
out=$(bash "$ENTRYPOINT" --forced_date=2026-10-08 --override_version=2.2641.0 2>&1); rc=$?
check "collision exits non-zero" "1" "$rc"
case "$out" in *"ERROR: tag '2.2641.0' already exists"*) ok "collision explains itself";;
               *) bad "collision explains itself" "got: $out";; esac
case "$out" in *"unbound variable"*) bad "collision message survives set -u" "bash error replaced the diagnostic";;
               *) ok "collision message survives set -u";; esac

# ---------------------------------------------------------------------------------------
# 4. Bootstrap: a tagless remote. The tag refspec matches nothing, which git reports as
#    exit 1 with NO message -- under `set -e` that killed the script with no diagnostic.
# ---------------------------------------------------------------------------------------
cd "$(make_repo tagless)"
out=$(bash "$ENTRYPOINT" --forced_date=2026-10-08 2>&1); rc=$?
check "tagless remote still tags" "0" "$rc"
check "  first tag is build 0" "version: 2.2641.0" "$(echo "$out" | grep '^version:')"
check "  and it reaches the remote" "2.2641.0" "$(remote_tags)"

# ---------------------------------------------------------------------------------------
# 5. Push scope: only the computed tag goes out. `--tags` would push everything local,
#    resurrecting tags deleted on purpose.
# ---------------------------------------------------------------------------------------
cd "$(make_repo pushscope 2.2641.0)"
git tag local-only-do-not-push
bash "$ENTRYPOINT" --forced_date=2026-10-08 >/dev/null 2>&1
check "pushes only the computed tag" "2.2641.0 2.2641.1" "$(remote_tags)"

# ---------------------------------------------------------------------------------------
# 6. Year-boundary corrections. Dead code until this change (they read an unassigned
#    ${forced_date}), now live and able to move the computed version by a whole year. A
#    wrong flip produces a tag that sorts BELOW everything and re-wedges the pipeline.
# ---------------------------------------------------------------------------------------
for case in "2025-12-29:2.2601.0:ISO week 1 in late December counts as next year" \
            "2027-01-01:2.2653.0:ISO week 53 on Jan 1 counts as last year" \
            "2026-06-15:2.2625.0:mid-year is left alone" ; do
    d=${case%%:*}; rest=${case#*:}; want=${rest%%:*}; label=${rest#*:}
    cd "$(make_repo "boundary_${d//-/}")"
    got=$(bash "$ENTRYPOINT" --forced_date="$d" 2>&1 | grep '^version:' | sed 's/^version: //')
    check "$label ($d)" "$want" "$got"
done

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
