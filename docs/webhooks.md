# Webhooks

Stripe tells your app what happened by posting events to it. The plugin
answers at `POST /stripe/webhook`.

## Setting up the endpoint

In the Stripe dashboard, under Developers > Webhooks, add an endpoint at
`https://your-app.example/stripe/webhook` with **API version
`2026-08-26.dahlia`** — the one the plugin pins. A webhook's payload
follows the endpoint's version, not the version a request asks for, so an
endpoint on another version sends shapes the plugin was not written
against. Select at least:

- `customer.subscription.created`, `.updated`, `.deleted`
- `checkout.session.completed`, `checkout.session.async_payment_succeeded`
- `invoice.payment_failed`

and any other event you listen for yourself. Copy the endpoint's signing
secret into `STRIPE_WEBHOOK_SECRET`.

## Locally

Stripe cannot reach `localhost`, so the Stripe CLI does: it listens to
your account and forwards each event, signed, to your app.

```sh
stripe listen --latest \
  --events customer.subscription.created,customer.subscription.updated,customer.subscription.deleted,checkout.session.completed,checkout.session.async_payment_succeeded,invoice.payment_failed \
  --forward-to localhost:8080/stripe/webhook
```

It prints a `whsec_...` of its own when it starts: that is the
`STRIPE_WEBHOOK_SECRET` while it runs. `--latest` sends events in the
newest API version rather than your account's default. The newest CLI
wants the events named; `--events` lists them.

Then do something in test mode — a checkout with the card `4242 4242
4242 4242`, any future date, any CVC — and watch the events arrive, each
answered `[200]`.

## What happens to an event

1. **The signature is checked** against the raw body and the
   `Stripe-Signature` header, with a five-minute window. A bad signature is
   a 400, and the reason goes to your log, not to whoever sent it. Without
   `STRIPE_WEBHOOK_SECRET` every event is refused with a 500 — never taken
   unverified — and Stripe sends it again once the secret is set.
2. **The event id is recorded in `stripe_events`**, in a transaction. A
   second delivery of the same event meets the unique index and changes
   nothing: no second row, no second dispatch.
3. **The event is applied** — a subscription written, a payment told —
   and the plugin's events are dispatched.
4. **The transaction commits**, and Stripe gets a 200.

If anything in 2 to 4 fails — the database, or a listener that raises —
the transaction rolls back and the answer is a 500. The event id is not
recorded, so Stripe's retry is not taken for a duplicate. In live mode
Stripe retries for up to three days; in test mode, a few times over a few
hours. That is the queue: it needs nothing from your app.

The route is in a group of its own, without CSRF and without your app's
rate limit. Stripe cannot send a token, and the signature is what the
token would have proved; and Stripe is one sender with a burst of events,
which should neither spend every visitor's allowance nor have its retries
refused by it.

## Order

Stripe does not promise order: `customer.subscription.updated` can arrive
before `.created`. Each subscription row keeps the Stripe time of what it
last applied, and an older event does not overwrite a newer state.

The older event is still recorded and still dispatched. **The listeners
hear every event once; the table holds the latest.**

## Events

Listen for them the way you listen for any Askr event:

```pascal
uses Askr.Events, Askr.Plugin.Stripe.Billing;

procedure Welcome(E: TEvent);
begin
  SendWelcomeMail(TStripeSubscriptionCreated(E).UserId);
end;

Listen(TStripeSubscriptionCreated, @Welcome);
```

| Event | When | Fields |
|---|---|---|
| `TStripeSubscriptionCreated` | `customer.subscription.created` | `UserId`, `SubscriptionId`, `Status`, `Price` |
| `TStripeSubscriptionUpdated` | `.updated`, `.paused`, `.resumed`, `.trial_will_end` | the same |
| `TStripeSubscriptionCancelled` | `.deleted` — it has ended | the same |
| `TStripePaymentSucceeded` | a one-off Checkout, paid | `UserId`, `SessionId`, `PaymentIntent`, `AmountTotal`, `Currency` |
| `TStripePaymentFailed` | `invoice.payment_failed` | `UserId`, `InvoiceId`, `SubscriptionId`, `AmountDue`, `Currency` |
| `TStripeEventReceived` | every event, after the above | `EventId`, `EventType`, `Payload` |

A cancellation at the period's end is an `Updated` with
`cancel_at_period_end`, and then a `Cancelled` when the period is over.

A listener runs inside the webhook's transaction: if it raises, nothing
the event did is kept, and Stripe sends it again. Work that is slow, or
that talks to something else, belongs in the queue — `ListenQueued` —
so the webhook answers in time: Stripe expects an answer within seconds,
and counts a slow one as failed.

A payment by bank debit completes the Checkout session **unpaid** and
settles days later; `TStripePaymentSucceeded` is dispatched when it is
paid, not when the session completes.

## Events the plugin does not handle

Every verified event is dispatched as a `TStripeEventReceived` after the
plugin's own, with the whole event as JSON. A refund, a dispute, an
invoice that was paid — listen for that, and read what you need:

```pascal
uses Askr.Events, Askr.Plugin.Stripe.Client, Askr.Plugin.Stripe.Billing;

procedure Refunded(E: TEvent);
var
  R: TStripeEventReceived;
begin
  R := TStripeEventReceived(E);
  if R.EventType <> 'charge.refunded' then
    Exit;
  MarkRefunded(R.EventId, R.Payload);
end;

Listen(TStripeEventReceived, @Refunded);
```

`R.Payload` is the event as Stripe sent it. `StripeField(Json, Key)` reads
a top-level string field; for anything deeper, `JsonParse` from
`Askr.Core.Json` reads the whole of it. Add the event to the endpoint's
list in the dashboard, or to `--events` locally, or Stripe never sends it.

## A subscription nobody here has

A subscription made in the dashboard, for a customer this app never made,
has nobody to belong to. It is looked up by the customer, then by
`askr_user_id` in the subscription's own metadata; found by neither, it is
logged, recorded and dispatched as a `TStripeEventReceived`, and given to
nobody. Guessing would give it to the wrong person.

## Testing your listeners

`StripeSignatureHeader` makes the header Stripe would send, so a test can
post an event of its own through the real route. See
[testing](testing.md).

## The rate limit

The webhook is outside your app's rate limit: the group it is in says
`WithoutRateLimit`. Nothing to do. A signature is what keeps anyone else
out of it, and a bad one costs a 400 and nothing else.
