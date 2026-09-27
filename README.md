# askr-stripe

Stripe billing for [Askr](https://github.com/kwhorne/askrcode) apps: a
customer per user, Checkout for subscriptions and one-off payments, the
customer portal, and webhooks that are verified, recorded once and applied
in a transaction.

```sh
askr plugin add https://github.com/kwhorne/askr-stripe.git
askr migrate
```

```pascal
uses Askr.Plugin.Stripe.Billing;

Result := Redirect(CheckoutUrl(Askr.Auth.Id, Email,
  SubscriptionCheckout('price_...', SuccessUrl, CancelUrl)), 303);

if Subscribed(Askr.Auth.Id, 'price_...') then ...
```

It needs Askr 0.17 or later: plugins came in 0.16, and the route groups
and nested transactions it uses in 0.17.

## Documentation

| | |
|---|---|
| [Getting started](docs/billing.md) | Install, configure, and sell a subscription and a product end to end |
| [Customers](docs/customers.md) | A Stripe customer per user, and the billing portal |
| [Subscriptions](docs/subscriptions.md) | Checkout, trials, checking status, paid pages, cancelling and resuming |
| [Payments](docs/payments.md) | One-off payments, failed payments, and 3-D Secure |
| [Webhooks](docs/webhooks.md) | The endpoint, what happens to an event, order, and the events you can listen for |
| [The Stripe API](docs/api.md) | Calling Stripe directly, errors and retries, idempotency, and the pinned version |
| [Testing](docs/testing.md) | Testing an app's billing without Stripe, and the plugin's own checks |

The same pages are on [askrcode.com](https://askrcode.com/plugins/stripe),
and an app's coding agent reads them through `askr mcp`, for the version
the app pins, as `stripe/billing.md` and so on. The code on every page is
compiled by `./check`.

## What it is held to

- **The Stripe-Signature check** agrees with stripe-python 15.6.1 on thirty
  headers -- valid, stale, tampered, malformed, several signatures, the
  edge of the window -- each with stripe-python's own verdict.
  `tools/signatures.py` writes them.
- **Every request the plugin makes** is accepted by
  [stripe-mock](https://github.com/stripe/stripe-mock), Stripe's server
  built from its OpenAPI spec. It refuses a top-level parameter Stripe
  does not have; it does not check the keys nested inside one, like
  `line_items[0][price]`.
- **The headers on the wire** -- the secret as a Bearer, the pinned
  `Stripe-Version`, the `Idempotency-Key`, a form body -- are read off a
  raw socket, not from the code that sets them.
- **Webhooks**: the same event twice has one effect; an older event does
  not overwrite a newer state; a failing listener rolls everything back
  and Stripe's retry applies it.
- **Inside a real app**: `./check --app` makes a new `askr new --auth`
  app, adds the plugin from a git tag, builds, migrates, and sends a
  signed webhook over HTTP through sessions, the rate limit and CSRF. It
  is the only place the CSRF exemption is proven.

Each of these was mutation-checked: the check removed, and the suite
required to fail.

**Against a real Stripe account, in test mode** (2026-09-26):
`./check --testmode` serves the app with `stripe listen` beside it, so the
account's own events, signed by Stripe, reach the webhook. A customer,
Checkout, the portal, a subscription paid by a test card, cancel, resume,
end, a trial and a declined card: fifteen events, each answered 200 and
recorded once, on API version `2026-08-26.dahlia`. That run found a bug
nothing else could -- a customer's idempotency key made of the user id,
which Stripe kept for a day and answered with a customer that had been
deleted -- and it is fixed.

**Not proven:** live mode, a real card, and a Checkout page completed by a
person. Test mode takes test cards only, and Checkout's page is a browser.

## Running the suite

```sh
./check            # needs Docker and a checkout of Askr at ../askrcode
./check --checks   # with range, overflow and I/O checks
./check --app      # the plugin inside a new --auth app
STRIPE_SECRET=sk_test_... ./check --testmode   # against your test account
```

`ASKR_PATH` points at another checkout. The suite builds in the
framework's own image, `askr-fpc:bookworm`, and starts stripe-mock beside
it.

## License

MIT.
