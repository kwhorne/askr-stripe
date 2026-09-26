# Changelog

## 0.1.0

The first release.

### Added

- A Stripe customer per user, keyed by the user id as text, made once
  with the user id as its idempotency key.
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

### Not yet

- A run against a real Stripe account. The suite holds the plugin to
  stripe-python's signature verdicts, to stripe-mock and to a raw socket,
  none of which is Stripe.
