#!/bin/bash
# Integration tests. Need root (snapshot deletion) and a btrfs directory:
#   sudo TEST_DIR=/some/btrfs/dir tests/run-tests.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
S="$here/src/btrfs-auto-snapshot"
base=${TEST_DIR:-$here}
[ "$(id -u)" -eq 0 ] || { echo "SKIP: run as root"; exit 0; }
[ "$(stat -f -c %T "$base")" = btrfs ] || { echo "SKIP: $base is not on btrfs (set TEST_DIR)"; exit 0; }

T=$(mktemp -d "$base/bas-test.XXXXXX")
fail=0
ok()  { echo "ok   - $*"; }
bad() { echo "FAIL - $*"; fail=1; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
cleanup() {
	find "$T" -depth -type d -inum 256 -exec btrfs -q subvolume delete {} \; 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT

btrfs -q subvolume create "$T/vol"
btrfs -q subvolume create "$T/vol/nested"
echo data > "$T/vol/file"
SD="$T/vol/.btrfs-auto-snapshot"
run() { "$S" --lockfile="$T/lock" -q "$@"; }

check "dry run creates nothing" run -n -l hourly "$T/vol"
check "no snapdir after dry run" test ! -e "$SD"

check "snapshot succeeds" run -l hourly "$T/vol"
snap=$(ls "$SD")
check "snapshot name format" bash -c "[[ '$snap' =~ ^btrfs-auto-snap_hourly-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}\$ ]]"
check "snapshot has data" grep -q data "$SD/$snap/file"
check "snapshot is read-only" bash -c "[ \"\$(btrfs property get -ts '$SD/$snap' ro)\" = ro=true ]"
check "same-minute rerun is refused" bash -c "! '$S' --lockfile='$T/lock' -q -l hourly '$T/vol'"

for d in 2000-01-01-0000 2000-01-01-0100 2000-01-01-0200; do
	btrfs -q subvolume snapshot -r "$T/vol" "$SD/btrfs-auto-snap_hourly-$d"
done
btrfs -q subvolume snapshot -r "$T/vol" "$SD/btrfs-auto-snap_daily-2000-01-01-0000"
check "destroy-only keep=2" run -l hourly -k 2 --destroy-only "$T/vol"
check "kept newest two hourly" test -e "$SD/$snap" -a -e "$SD/btrfs-auto-snap_hourly-2000-01-01-0200"
check "deleted older hourly" test ! -e "$SD/btrfs-auto-snap_hourly-2000-01-01-0100" -a ! -e "$SD/btrfs-auto-snap_hourly-2000-01-01-0000"
check "other labels untouched" test -e "$SD/btrfs-auto-snap_daily-2000-01-01-0000"

check "recursive snapshot" run -l weekly -r "$T/vol"
check "nested subvolume snapshotted" bash -c "ls '$T/vol/nested/.btrfs-auto-snapshot' | grep -q weekly"
check "snapshot dirs not snapshotted" test ! -e "$SD/.btrfs-auto-snapshot"

if command -v setfattr >/dev/null; then
	setfattr -n user.auto-snapshot:monthly -v false "$T/vol"
	run -l monthly "$T/vol"
	check "xattr opt-out honoured" bash -c "! ls '$SD' | grep -q monthly"
	check "default-exclude skips unmarked" run -l custom --default-exclude "$T/vol/nested"
	check "nothing created with default-exclude" bash -c "! ls '$T/vol/nested/.btrfs-auto-snapshot' | grep -q custom"
else
	echo "skip - xattr tests (install 'attr' for setfattr)"
fi

mkdir "$T/snaps"
check "absolute snaproot" run -l daily -r -S "$T/snaps" "$T/vol"
check "absolute snaproot has snapshot" bash -c "find '$T/snaps' -path '*/vol/btrfs-auto-snap_daily-*' -inum 256 | grep -q ."
check "absolute snaproot has nested" bash -c "find '$T/snaps' -path '*/vol/nested/btrfs-auto-snap_daily-*' -inum 256 | grep -q ."

# Relative snaproot: lives at the filesystem top level, mounted privately.
rel="bas-test-snaps-$$"
check "relative snaproot" run -l daily -S "$rel" "$T/vol"
check "relative snaproot not mounted afterwards" bash -c "! findmnt -rn -o TARGET | grep -q '^/run/btrfs-auto-snapshot\\.'"
uuid=$(findmnt -n -o UUID -T "$T/vol")
top=$(mktemp -d)
if mount -o subvolid=5 "UUID=$uuid" "$top"; then
	check "relative snaproot is a subvolume" test "$(stat -c %i "$top/$rel")" = 256
	check "relative snaproot has snapshot" bash -c "find '$top/$rel' -path '*/vol/btrfs-auto-snap_daily-*' -inum 256 | grep -q ."
	find "$top/$rel" -depth -type d -inum 256 -exec btrfs -q subvolume delete {} \; 2>/dev/null
	rm -rf "${top:?}/$rel"
	umount "$top"
else
	bad "cannot mount top level to check relative snaproot"
fi
rmdir "$top"

check "rejects non-subvolume" bash -c "! '$S' -q -n /proc 2>/dev/null"
check "rejects bad keep" bash -c "! '$S' -q -n -k abc '$T/vol' 2>/dev/null"

[ $fail -eq 0 ] && echo "All tests passed." || echo "Some tests FAILED."
exit $fail
