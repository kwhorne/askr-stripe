# askr-stripe

Stripe billing for an Askr app. Stripe's hosted Checkout takes the card,
Stripe's portal lets a customer manage it, and your app keeps a copy of
what Stripe said — customers, subscriptions, the events that changed them
— in four tables it can ask questions of.

These pages are the plugin's own, at the version your project pins. An
agent reads the same pages through `askr mcp`, as `stripe/billing.md` and
so on.

---

## Start here

| | |
|---|---|
| [Getting started](billing.md) | Install, configure, and sell a subscription and a product end to end |

## Billing

| | |
|---|---|
| [Customers](customers.md) | A Stripe customer per user, and the billing portal |
| [Subscriptions](subscriptions.md) | Checkout, trials, checking status, paid pages, cancelling and resuming |
| [Payments](payments.md) | One-off payments, failed payments, and 3-D Secure |

## Stripe's side

| | |
|---|---|
| [Webhooks](webhooks.md) | The endpoint, what happens to an event, order, and the events you can listen for |
| [The Stripe API](api.md) | Calling Stripe directly, errors and retries, idempotency, and the pinned version |
| [Testing](testing.md) | Testing an app's billing without Stripe, and the plugin's own checks |
