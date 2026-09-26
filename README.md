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

It needs Askr 0.16 or later, the first release with plugins. The guides
are in [`docs/`](docs), and an app's coding agent reads them for the
version it pins through `askr mcp`, as `stripe/billing.md` and
`stripe/webhooks.md`.

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

**Not yet: a run against a real Stripe account.** None of the above is
Stripe itself. Until a test-mode account has taken a checkout and sent its
webhooks here, this line stays.

## Running the suite

```sh
./check            # needs Docker and a checkout of Askr at ../askrcode
./check --checks   # with range, overflow and I/O checks
./check --app      # the plugin inside a new --auth app
```

`ASKR_PATH` points at another checkout. The suite builds in the
framework's own image, `askr-fpc:bookworm`, and starts stripe-mock beside
it.

## License

MIT.
