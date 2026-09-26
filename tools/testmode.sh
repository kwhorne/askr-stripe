#!/usr/bin/env bash
# ./check --testmode: one run against a real Stripe account in test mode.
#
#   STRIPE_SECRET=sk_test_... ./check --testmode
#
# Builds the app ./check --app builds, serves it, and runs `stripe listen`
# beside it, so the account's real events -- signed by Stripe -- reach the
# app's /stripe/webhook. examples/testmode.lpr then drives the account
# through the plugin and waits for what the webhooks write.
#
# The key is passed by name in the environment, never on a command line,
# and nothing here prints it. A live key is refused.
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
ASKR=$1
IMAGE=askr-fpc:bookworm
NET=askr-stripe-testmode
APP=askr-stripe-app
CLI=askr-stripe-cli
ws=.build/app-check

case "${STRIPE_SECRET:-}" in
  sk_test_*) ;;
  *) echo "Set STRIPE_SECRET to a test-mode key, sk_test_...: this run makes and deletes things in the account." >&2
     exit 2 ;;
esac
export STRIPE_API_KEY="$STRIPE_SECRET"

echo "Building the app ..."
"$HERE/tools/app-check.sh" "$ASKR" > "$HERE/.build/app-check.log" 2>&1 || {
  echo "The app did not build and pass ./check --app first:" >&2
  tail -8 "$HERE/.build/app-check.log" >&2
  exit 1
}

cleanup() {
  docker rm -f "$CLI" "$APP" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
docker network create "$NET" >/dev/null

# The signing secret `stripe listen` signs with. Into the environment, by
# name, like the key.
STRIPE_WEBHOOK_SECRET=$(docker run --rm -e STRIPE_API_KEY stripe/stripe-cli:latest \
  listen --print-secret 2>/dev/null | tr -d '\r\n')
case "$STRIPE_WEBHOOK_SECRET" in
  whsec_*) export STRIPE_WEBHOOK_SECRET ;;
  *) echo "stripe listen gave no signing secret; is the key valid?" >&2; exit 1 ;;
esac

# The events the plugin handles, and three it only records.
EVENTS=customer.subscription.created,customer.subscription.updated,customer.subscription.deleted,customer.subscription.trial_will_end,checkout.session.completed,checkout.session.async_payment_succeeded,invoice.payment_failed,invoice.paid,customer.created,customer.deleted
# --latest: events in the newest API version rather than the account's
# default, which is what an endpoint created on 2026-08-26.dahlia gets.
docker run -d --name "$CLI" --network "$NET" -e STRIPE_API_KEY \
  stripe/stripe-cli:latest listen --latest --events "$EVENTS" \
  --forward-to "http://$APP:8472/stripe/webhook" >/dev/null
for i in $(seq 1 40); do
  docker logs "$CLI" 2>&1 | grep -q 'Ready!' && break
  sleep 0.5
done
docker logs "$CLI" 2>&1 | grep -q 'Ready!' || {
  echo "stripe listen did not get ready:" >&2
  docker logs "$CLI" 2>&1 | grep -v whsec_ | tail -5 >&2
  exit 1
}

U=/askr/src
FLAGS="-B -Sh -O2 -gl -vew -Fu$U/cli -Fu$U/core -Fu$U/http -Fu$U/urd \
  -Fu$U/norn -Fu$U/inertia -Fu$U/desktop -Fu$U/runtime -Fu$U/run \
  -Fu/plugin/src -FU/plugin/.build/testmode-units -FE/plugin/.build/testmode-bin"
code=0
docker run --rm --name "$APP" --network "$NET" \
  -e STRIPE_SECRET -e STRIPE_WEBHOOK_SECRET \
  -e DATABASE_URL=sqlite:storage/testmode.sqlite -e ASKR_HOME=/askr \
  -v "$ASKR":/askr:ro -v "$HERE":/plugin -w "/plugin/$ws/shop" "$IMAGE" sh -c "
    mkdir -p /plugin/.build/testmode-units /plugin/.build/testmode-bin &&
    fpc $FLAGS /plugin/examples/testmode.lpr > /plugin/.build/testmode-fpc.log 2>&1 || {
      grep -E 'Error|Fatal' /plugin/.build/testmode-fpc.log; exit 3; }
    rm -f storage/testmode.sqlite && /plugin/$ws/bin/askr migrate > /dev/null &&
    (.build/bin/app 8472 0.0.0.0 > /plugin/.build/testmode-app.log 2>&1 &) &&
    for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null http://127.0.0.1:8472/ && break; sleep 0.3; done
    /plugin/.build/testmode-bin/testmode" || code=$?

echo
echo "What stripe listen forwarded, and what the app answered:"
docker logs "$CLI" 2>&1 | grep -E -- '-->|<--|[Ee]rror' | grep -v whsec_ |
  sed -E 's/^[0-9-]+ [0-9:]+ +//' | sort | uniq -c | sort -rn | head -30
exit $code
