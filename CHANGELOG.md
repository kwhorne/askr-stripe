# Changelog

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
