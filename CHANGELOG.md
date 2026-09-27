# Changelog

## 0.3.0

Built on Askr 0.17's route groups and nested transactions, and needs it.

### Changed

- **The webhook is in a group without CSRF and without the app's rate
  limit**, in place of `CsrfExempt`. Stripe is one sender with a burst of
  events: it should not spend every visitor's allowance, nor have its
  retries refused with a 429. A test drives the plugin's own `Routes`
  behind a rate limit and requires the webhook through and a route beside
  it refused; `./check --app` requires the webhook through CSRF.
- **The webhook and a new customer's row use `C.Transaction`.** Inside a
  caller's transaction -- a test's sandbox, say -- each is a savepoint, so
  a duplicate event or a customer made twice rolls back only itself.
  Before, a unique violation there left a caller's transaction aborted on
  Postgres. The plugin's suite runs on SQLite, where it never was; what
  holds this on Postgres is the framework's own test of `C.Transaction`.

## 0.2.0

Documentation to build billing on, in the shape Laravel Cashier's has:
getting started, customers, subscriptions, payments, webhooks, the Stripe
API and testing, each with the code an app writes. The code on every page
is compiled by `./check`, from `examples/docs.lpr`, and a line on a page
that is not in that file stops the check -- so a page cannot show a
function that does not exist.

### Added

- `RequireSubscribed(Price, PricingPath)`: a paid page asks for itself,
  in the shape of `RequireVerified` -- a 303 to the pricing page for a
  browser, Inertia's 409 for an Inertia visit, a 402 for a JSON client.
  Unlike `RequireVerified` it refuses somebody who is not signed in too,
  so a forgotten `RequireAuth` does not give a paid page away.
- `TCheckout.Extra`: any parameter Checkout takes, in Stripe's names --
  a trial without a card is
  `C.Extra.Add('payment_method_collection', 'if_required')`.
- `TStripeSubscription.ItemIds`, beside `Prices`: Stripe changes an item
  by its `si_...` id, which is what changing a plan through the API needs.
- `TStripeParams.Append`.

## 0.1.0

The first release.

### Added

- A Stripe customer per user, keyed by the user id as text, made once;
  when two requests race, the loser deletes the customer it made.
- Checkout for subscriptions -- with a trial, several prices, promotion
  codes -- and for one-off payments.
- The customer portal.
- `Subscribed`, `OnTrial`, `OnGracePeriod` and `FindSubscription`.
- `CancelSubscription`, `ResumeSubscription` and `CancelSubscriptionNow`,
  which apply Stripe's reply at once.
- `POST /stripe/webhook`: the signature checked against the raw body with
  a five-minute window; each event recorded once and applied in one
  transaction; an older event never overwriting a newer subscription
  state; a 500, and Stripe's retry, when anything fails.
- Events: `TStripeSubscriptionCreated`, `TStripeSubscriptionUpdated`,
  `TStripeSubscriptionCancelled`, `TStripePaymentSucceeded`,
  `TStripePaymentFailed` and `TStripeEventReceived`.
- Stripe-Version pinned to `2026-08-26.dahlia`, and an Idempotency-Key on
  every POST.

### Held to

- stripe-python's verdicts on thirty Stripe-Signature headers, stripe-mock,
  the bytes on a raw socket, and a new `--auth` app taking a signed webhook
  over HTTP.
- A real Stripe account in test mode, with `stripe listen` forwarding its
  events: fifteen, each answered and recorded once.

### Not proven

- Live mode, a real card, and a Checkout page completed in a browser.
