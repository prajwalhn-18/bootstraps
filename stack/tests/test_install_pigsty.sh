# stack/tests/test_install_pigsty.sh
SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../database/install-pigsty.sh"
source "$SCRIPT" --source-only 2>/dev/null || true   # allow sourcing for pigsty::install_cmd

out=$(bash "$SCRIPT" --host local --dry-run)
assert_contains "$out" "deploy.yml" "dry-run prints the deploy.yml step"

bash "$SCRIPT" --host local --dry-run >/dev/null; assert_success "$?" "dry-run on a valid local host exits 0"

( bash "$SCRIPT" --host "not a host" --dry-run ) 2>/dev/null
assert_failure "$?" "rejects a malformed --host before doing anything"

( bash "$SCRIPT" --dry-run ) 2>/dev/null
assert_failure "$?" "requires --host"

( pigsty::is_reachable "local" 59999 ) 2>/dev/null
assert_failure "$?" "is_reachable: nothing listening on an unused port is not reachable"

nc -l 59998 >/dev/null 2>&1 &
NC_PID=$!
sleep 0.3
pigsty::is_reachable "local" 59998
assert_success "$?" "is_reachable: a listening port is reachable"
kill "$NC_PID" >/dev/null 2>&1
