#!/usr/bin/env bash
# Unit tests for the sync_routes() function in update_wireguard.sh.j2
# No root, no WireGuard daemon, no network required.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/update_scripts/update_wireguard.sh.j2"

FAKE_IP4_TABLE=""
FAKE_IP6_TABLE=""
ROUTE_OPS=()

ip() {
    # Called as: ip [-4|-6] route show dev <iface>  OR  ip [-4|-6] route add/del ...
    local _args="$*"
    case "$_args" in
        *"-4 route show"*) echo "$FAKE_IP4_TABLE" ;;
        *"-6 route show"*) echo "$FAKE_IP6_TABLE" ;;
        *) ROUTE_OPS+=("$_args") ;;
    esac
}
sudo() { "$@"; }
assert_exit_code() { :; }
log_with_timestamp() { :; }

# sync_routes contains no Jinja2 tokens, so sed can extract it directly.
# The closing } of sync_routes is at column 0; _normalize_prefix's is indented.
_fn_tmp=$(mktemp --suffix=.sh)
sed -n '/^sync_routes() {/,/^}/p' "$TEMPLATE" > "$_fn_tmp"

# shellcheck source=/dev/null
source "$_fn_tmp"
rm -f "$_fn_tmp"

PASS=0
FAIL=0

_pass() { echo "      PASS $1"; PASS=$((PASS + 1)); }
_fail() { echo "      FAIL $1"; FAIL=$((FAIL + 1)); }

assert_contains() {
    local desc="$1" pattern="$2"
    local op
    for op in "${ROUTE_OPS[@]+"${ROUTE_OPS[@]}"}"; do
        [[ "$op" == *"$pattern"* ]] && { _pass "$desc"; return; }
    done
    _fail "$desc"
    echo "      expected pattern: '$pattern'"
    echo "      recorded ops: [${ROUTE_OPS[*]:-<none>}]"
}

assert_not_contains() {
    local desc="$1" pattern="$2"
    local op
    for op in "${ROUTE_OPS[@]+"${ROUTE_OPS[@]}"}"; do
        [[ "$op" == *"$pattern"* ]] && {
            _fail "$desc"
            echo "      unexpected pattern found: '$pattern'"
            return
        }
    done
    _pass "$desc"
}

# Reset state and call sync_routes with controlled inputs.
# Stdin is redirected from /dev/null so the heredoc inside sync_routes never
# blocks on a terminal even if the ip stub returns an empty string.
# Args: <conf_content> <fake_ipv4_table> <fake_ipv6_table> <interface>
run_case() {
    local conf_content="$1" fake4="$2" fake6="$3" iface="$4"
    local conf_file
    conf_file=$(mktemp)
    printf '%s\n' "$conf_content" > "$conf_file"
    FAKE_IP4_TABLE="$fake4"
    FAKE_IP6_TABLE="$fake6"
    ROUTE_OPS=()
    sync_routes "$iface" "$conf_file" < /dev/null
    rm -f "$conf_file"
}

echo "sync_routes unit tests:"
echo ""

echo "1. Adds a new IPv4 host route (/32 is normalized away)"
run_case \
    "[Peer]
AllowedIPs = 10.0.0.2/32" \
    "" "" "wg0"
assert_contains     "ip -4 route add called"    "-4 route add 10.0.0.2 dev wg0"
assert_not_contains "no route del on empty table" "route del"
echo ""

echo "2. Removes a stale IPv4 route and adds the new one"
run_case \
    "[Peer]
AllowedIPs = 10.0.0.3/32" \
    "10.0.0.2 dev wg0 scope link" "" "wg0"
assert_contains "stale route deleted"     "-4 route del 10.0.0.2 dev wg0"
assert_contains "replacement route added" "-4 route add 10.0.0.3 dev wg0"
echo ""

echo "3. proto kernel route is skipped — never deleted or re-added"
run_case \
    "[Peer]
AllowedIPs = 10.0.0.0/24" \
    "10.0.0.0/24 dev wg0 proto kernel scope link src 10.0.0.1" "" "wg0"
assert_not_contains "kernel route not deleted"  "route del 10.0.0.0"
assert_not_contains "kernel route not re-added" "route add 10.0.0.0/24"
echo ""

echo "4. Adds an IPv6 host route (/128 is normalized away)"
run_case \
    "[Peer]
AllowedIPs = fd00::2/128" \
    "" "" "wg0"
assert_contains     "ip -6 route add called"      "-6 route add fd00::2 dev wg0"
assert_not_contains "no IPv4 route add for IPv6"  "-4 route add fd00"
echo ""

echo "5. Comma-separated AllowedIPs on a single line"
run_case \
    "[Peer]
AllowedIPs = 192.168.1.1/32, 192.168.1.2/32" \
    "" "" "wg0"
assert_contains "first comma entry added"  "-4 route add 192.168.1.1 dev wg0"
assert_contains "second comma entry added" "-4 route add 192.168.1.2 dev wg0"
echo ""

echo "6. No-op when conf and active routes match exactly"
run_case \
    "[Peer]
AllowedIPs = 10.0.0.5/32" \
    "10.0.0.5 dev wg0 scope link" "" "wg0"
assert_not_contains "no add when already present" "route add 10.0.0.5"
assert_not_contains "no del when still needed"    "route del 10.0.0.5"
echo ""

echo "7. Mixed IPv4 and IPv6 AllowedIPs in a single peer"
run_case \
    "[Peer]
AllowedIPs = 10.1.0.1/32, fd00::1/128" \
    "" "" "wg0"
assert_contains "IPv4 route added for mixed peer" "-4 route add 10.1.0.1 dev wg0"
assert_contains "IPv6 route added for mixed peer" "-6 route add fd00::1 dev wg0"
echo ""

echo "8. Multiple [Peer] blocks with separate AllowedIPs lines"
run_case \
    "[Peer]
AllowedIPs = 10.0.1.0/24
[Peer]
AllowedIPs = 10.0.2.0/24" \
    "" "" "wg0"
assert_contains "first peer subnet added"  "-4 route add 10.0.1.0/24 dev wg0"
assert_contains "second peer subnet added" "-4 route add 10.0.2.0/24 dev wg0"
echo ""

printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
echo ""
[[ $FAIL -eq 0 ]]
