# Billing

Stripe billing for an Askr app: a customer per user, Checkout for
subscriptions and one-off payments, the customer portal, and the
questions an app asks about a user's subscription.

```sh
askr plugin add https://github.com/kwhorne/askr-stripe.git
askr migrate
```

```sh
# .env
STRIPE_SECRET=sk_test_...
STRIPE_WEBHOOK_SECRET=whsec_...
```

| Setting | |
|---|---|
| `STRIPE_SECRET` | The secret key, `sk_test_...` or `sk_live_...` |
| `STRIPE_WEBHOOK_SECRET` | The webhook endpoint's signing secret, `whsec_...` |
| `STRIPE_WEBHOOK_PATH` | `/stripe/webhook` unless set |
| `STRIPE_WEBHOOK_TOLERANCE` | Seconds a signature stays good; 300 |
| `STRIPE_BASE_URL` | `https://api.stripe.com` unless set; stripe-mock in tests |

A missing secret does not stop the app: it is logged when the app starts,
and every call to Stripe raises an `EStripeError` naming the variable. An
app has to be able to run its migrations and its own tests before it has a
Stripe account.

## A customer per user

The framework does not own your user model, so a Stripe customer is keyed
by the user id as text -- the id `Login` takes.

```pascal
uses Askr.Plugin.Stripe.Billing;

Customer := EnsureStripeCustomer(Askr.Auth.Id, Email, Name);
```

The first call makes the customer in Stripe, with the user id in its
metadata as `askr_user_id`, and keeps the id in `stripe_customers`; later
calls read it. Two requests racing to make one can both make one in
Stripe; the row decides, and the loser deletes its own. You rarely call it
yourself: a checkout does.

## Checkout

Stripe's hosted Checkout takes the card, 3-D Secure and SCA. Nothing about
a card passes through your app.

```pascal
function Subscribe(Req: TRequest): TResponse;
var
  C: TCheckout;
begin
  C := SubscriptionCheckout('price_1Q...',
    'https://shop.example/billing/done',
    'https://shop.example/pricing');
  C.TrialDays := 14;
  Result := Redirect(CheckoutUrl(Askr.Auth.Id, UserEmail, C), 303);
end;
```

A one-off payment is the same with `PaymentCheckout(Price, Quantity,
SuccessUrl, CancelUrl)`. `C.Add(Price, Quantity)` adds another line;
`C.AllowPromotionCodes` shows Stripe's promotion code field;
`C.IdempotencyKey` makes a retried request return the same session.

The success url is where the user lands, **not** proof of payment. A user
can close the tab before it loads, and anyone can type it. What happened
arrives as a webhook -- see [webhooks](webhooks.md).

## The customer portal

```pascal
Result := Redirect(BillingPortalUrl(Askr.Auth.Id,
  'https://shop.example/account'), 303);
```

Stripe's own page for a card, an invoice, a plan change or a cancellation.
What the portal allows is set in the Stripe dashboard. It raises when the
user has no customer yet.

## Asking about a subscription

| | |
|---|---|
| `Subscribed(UserId)` | A subscription that is active or trialing |
| `Subscribed(UserId, Price)` | ... with that price among its items |
| `OnTrial(UserId)` | Trialing, and the trial has not ended |
| `OnGracePeriod(UserId)` | Cancelled, and still running to the end of what was paid for |
| `FindSubscription(UserId, S)` | The subscription itself: status, prices, period end |

`past_due` is not subscribed: the renewal failed, and Stripe is retrying.
Whether that should lock someone out at once is your decision -- read
`S.Status` if it should not.

A cancelled subscription stays `active` until the period ends, so
`Subscribed` is true through the grace period, which is what was paid for.

## Cancelling and resuming

```pascal
CancelSubscription(UserId);      { at the end of the period }
ResumeSubscription(UserId);      { take that back, while it still runs }
CancelSubscriptionNow(UserId);   { ends it now }
```

Each applies Stripe's reply to the table at once, so the next page shows
it; the webhook for the same change arrives a moment later and changes
nothing further.

## Money

Stripe counts in minor units -- øre, cents -- as integers, and so does
this plugin: `AmountTotal` of 12900 is 129.00. Into `Currency` by
assignment, never by a cast:

```pascal
Amount := E.AmountTotal;   { then divide by 100 for display }
```

A cast reinterprets the bits instead of converting the value, and gives a
different answer on x86_64 than on arm64.

## The tables

| Table | |
|---|---|
| `stripe_customers` | user id to Stripe customer |
| `stripe_subscriptions` | each subscription as Stripe last described it |
| `stripe_subscription_items` | its prices and quantities |
| `stripe_events` | every webhook event id, once |

They hold what Stripe said, never what the app asked for. Times are
Stripe's unix seconds, in columns named as Stripe names them.

## What this does not do

- **Invoices as PDF, metered billing, Stripe Tax and Connect** are not in
  0.1. Each is a Stripe product with its own surface, and none of them is
  needed to take a subscription.
- **No card form.** Checkout and the portal are Stripe's pages. A form in
  your app would bring the card into your app, and with it PCI scope.
- **No Stripe objects in Pascal.** The plugin reads the fields it needs
  from the JSON. For anything else, `Stripe.Get('/v1/...')` returns the
  JSON, and `TStripeEventReceived.Payload` carries every webhook's.
