#!/usr/bin/env bash
# ./check --app: the plugin inside a real app, which the suite cannot be.
#
# A new `askr new --auth` app -- sessions, CSRF, rate limit and sign-in all
# on -- adds the plugin from a git tag, builds, migrates, and takes a
# signed webhook over HTTP through that whole stack. Then the docs over
# MCP. It is the only place the CSRF exemption is proven: the suite drives
# the route through a router without the middleware, and a mutation that
# drops the exemption goes through it untouched. Here it is a 419.
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
ASKR=$1
IMAGE=askr-fpc:bookworm
fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; shift; [ $# -gt 0 ] && printf '        %s\n' "$@"; fail=1; }

ws=.build/app-check
rm -rf "$HERE/$ws"
mkdir -p "$HERE/$ws"
gitc='git -c user.email=check@example.com -c user.name=check'
askr_bin=/plugin/$ws/bin/askr
in_box() {
  docker run --rm -v "$ASKR":/askr:ro -v "$HERE":/plugin -e ASKR_HOME=/askr \
    -e ASKR_CACHE="/plugin/$ws/cache" -w "/plugin/$ws${2:+/$2}" "$IMAGE" sh -c "$1"
}

U=/askr/src
if ! in_box "mkdir -p bin units && fpc -B -Sh -O2 -vew -Fu$U/cli -Fu$U/core \
    -Fu$U/http -Fu$U/urd -Fu$U/norn -Fu$U/inertia -Fu$U/desktop -Fu$U/runtime \
    -Fu$U/run -FUunits -FEbin /askr/cli/askr.lpr" > "$HERE/$ws/cli.log" 2>&1; then
  bad "the askr tool builds from $ASKR" "$(grep -E 'rror|Fatal' "$HERE/$ws/cli.log" | head -3)"
  exit 1
fi

# The copy is what gets tagged, so the checkout's own history is not
# touched. If the framework checkout does not meet the manifest's range --
# main between releases -- the copy says "*" and this line says so, rather
# than the build refusing for a reason that is not the plugin's.
# The copy is tagged as what its manifest says it is: plugin add refuses a
# tag whose manifest says otherwise.
version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$HERE/askr-plugin.toml")
have=$(grep -Eo "AskrVersion *= *'[^']+'" "$ASKR/src/core/Askr.Core.Version.pas" | grep -Eo "[0-9]+\.[0-9]+\.[0-9]+")
want=$(grep -E '^askr *=' "$HERE/askr-plugin.toml" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')
relax=""
if [ "${have%.*}" != "${want%.*}" ]; then
  echo "  note  $ASKR is Askr $have and the manifest wants ^$want; the copy builds against it anyway"
  relax="sed -i 's/^askr = .*/askr = \"*\"/' askr-stripe/askr-plugin.toml &&"
fi

out=$(in_box "mkdir -p askr-stripe && cp -r /plugin/askr-plugin.toml /plugin/src \
    /plugin/database /plugin/docs askr-stripe/ && $relax
  (cd askr-stripe && git init -q && $gitc add -A && $gitc commit -qm s && git tag v$version) &&
  $askr_bin new shop --auth" 2>&1) || true
if [ ! -f "$HERE/$ws/shop/askr.toml" ]; then
  bad "a new --auth app" "$(echo "$out" | tail -4)"
  exit 1
fi
# Docker Desktop's mount cache can hand the container a file written on
# the host a moment ago at its old length: the copy then ends mid-line and
# the build fails on a unit that is fine. Compare, and copy again.
for try in 1 2 3; do
  same=1
  for f in $(cd "$HERE" && find src database docs -type f); do
    [ "$(wc -c < "$HERE/$f")" = "$(wc -c < "$HERE/$ws/askr-stripe/$f" 2>/dev/null)" ] || same=0
  done
  [ $same -eq 1 ] && break
  sleep 1
  in_box "cd askr-stripe && rm -rf src database docs && cp -r /plugin/src /plugin/database /plugin/docs . &&
    $gitc add -A && $gitc commit -qm again && git tag -f v$version >/dev/null" > /dev/null 2>&1
done
[ $same -eq 1 ] || { bad "the plugin is copied whole" "the container keeps seeing old file sizes"; exit 1; }
sed -i.bak 's|^version = .*|path = "/askr"|; s|^path = .*|path = "/askr"|' "$HERE/$ws/shop/askr.toml"
sed -i.bak 's|^DATABASE_URL=.*|DATABASE_URL=sqlite:storage/check.sqlite|' "$HERE/$ws/shop/.env"
rm -f "$HERE/$ws/shop/"*.bak
printf '\nSTRIPE_SECRET=sk_test_check\nSTRIPE_WEBHOOK_SECRET=whsec_check\n' >> "$HERE/$ws/shop/.env"
ok "a new --auth app"

code=0; in_box "$askr_bin plugin add file:///plugin/$ws/askr-stripe" shop > "$HERE/$ws/add.log" 2>&1 || code=$?
if [ $code -eq 0 ] && grep -q '^\[plugins.stripe\]' "$HERE/$ws/shop/askr.toml"; then
  ok "askr plugin add, from the tag v$version"
else
  # Everything after this would test an app without the plugin, and some
  # of it would pass: the app builds fine without it.
  bad "askr plugin add" "$(tail -4 "$HERE/$ws/add.log")"
  exit 1
fi

if in_box "$askr_bin build" shop > "$HERE/$ws/build.log" 2>&1 &&
   grep -q 'Askr.Plugin.Stripe' "$HERE/$ws/shop/.build/plugins/App.Plugins.pas" 2>/dev/null; then
  ok "the app builds with the plugin compiled in"
else
  bad "the app builds" "$(grep -E 'rror|Fatal|askr:' "$HERE/$ws/build.log" | head -8)"
  exit 1
fi

in_box "$askr_bin migrate" shop > "$HERE/$ws/migrate.log" 2>&1 || true
if grep -q 'stripe:20261001000000' "$HERE/$ws/migrate.log"; then
  ok "the migration runs, under stripe:"
else
  bad "the migration runs" "$(tail -4 "$HERE/$ws/migrate.log")"
fi

cat > "$HERE/$ws/hook.py" <<'EOF'
import hmac, hashlib, json, time, urllib.request, urllib.error, sqlite3
url = "http://127.0.0.1:8472/stripe/webhook"
now = int(time.time())
sub = {"id": "sub_check", "object": "subscription", "customer": "cus_check",
       "status": "active", "items": {"object": "list", "data": [{"id": "si_1",
       "price": {"id": "price_pro"}, "quantity": 1, "current_period_end": now + 86400}]},
       "trial_end": None, "cancel_at": None, "ended_at": None,
       "cancel_at_period_end": False, "metadata": {"askr_user_id": "7"}}
body = json.dumps({"id": "evt_check", "object": "event", "created": now,
                   "type": "customer.subscription.created", "data": {"object": sub}})
def post(sig):
    req = urllib.request.Request(url, data=body.encode(), method="POST",
        headers={"Content-Type": "application/json", "Stripe-Signature": sig})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
mac = hmac.new(b"whsec_check", f"{now}.{body}".encode(), hashlib.sha256).hexdigest()
print("first", *post(f"t={now},v1={mac}"))
print("again", *post(f"t={now},v1={mac}"))
print("badsig", *post(f"t={now},v1={'0' * 64}"))
db = sqlite3.connect("storage/check.sqlite")
print("events", db.execute("select count(*) from stripe_events").fetchone()[0])
row = db.execute("select user_id, status, price from stripe_subscriptions").fetchone()
print("sub", *(row or ("none",)))
EOF
out=$(in_box ".build/bin/app 8472 > ../app.log 2>&1 &
  for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null http://127.0.0.1:8472/ && break; sleep 0.3; done
  python3 ../hook.py" shop 2>&1) || true
line() { echo "$out" | grep -q "$1"; }
line '^first 200 {"received":true}' && ok "a signed webhook through sessions, the rate limit and CSRF" ||
  bad "a signed webhook is taken" "$(echo "$out" | grep '^first')"
line '^again 200' && ok "the same event again is answered" || bad "the second delivery"
line '^badsig 400' && ok "a bad signature is refused" || bad "a bad signature is refused"
line '^events 1$' && ok "one event row" || bad "one event row" "$(echo "$out" | grep '^events')"
line '^sub 7 active price_pro$' && ok "the subscription is the user's" ||
  bad "the subscription row" "$(echo "$out" | grep -E '^sub|Error')"

printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"docs_read","arguments":{"page":"stripe/webhooks","section":"Order"}}}' \
  > "$HERE/$ws/frames.jsonl"
in_box "$askr_bin mcp < ../frames.jsonl" shop > "$HERE/$ws/mcp.log" 2>&1 || true
if grep '"id":2' "$HERE/$ws/mcp.log" | grep -q 'the table holds the latest'; then
  ok "an agent reads the docs as stripe/webhooks.md"
else
  bad "the docs over MCP" "$(tail -2 "$HERE/$ws/mcp.log" | cut -c1-200)"
fi

[ $fail -eq 0 ] && echo "app check: ok" || echo "app check: FAILED"
exit $fail
