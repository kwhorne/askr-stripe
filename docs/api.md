# The Stripe API

The plugin's functions cover Checkout, the portal and subscriptions. For
everything else Stripe has, `Stripe` is the client the plugin itself
uses, with the same secret, the same pinned version and the same errors.

## Calling Stripe

```pascal
uses Askr.Plugin.Stripe.Client, Askr.Plugin.Stripe.Billing;

var
  P: TStripeParams;
  Json: string;
begin
  { The user's last ten invoices. }
  Json := Stripe.Get('/v1/invoices?limit=10&customer=' +
    StripeCustomerId(UserId));

  { A one-off amount on their next invoice. }

  P := Default(TStripeParams);
  P.Add('amount', 5000);
  P.Add('currency', 'nok');
  P.Add('customer', StripeCustomerId(UserId));
  P.Add('description', 'Setup fee');
  Json := Stripe.Post('/v1/invoiceitems', P);
end;
```

| | |
|---|---|
| `Stripe.Post(Path, Params, IdempotencyKey)` | A POST with a form body; the key is optional |
| `Stripe.Get(Path)` | A GET; put a query in the path |
| `Stripe.Delete(Path)` | A DELETE |

Each returns Stripe's reply as JSON text, or raises an `EStripeError`.
`StripeField(Json, 'id')` reads one top-level string field; `JsonParse` in
`Askr.Core.Json` reads the rest.

## Parameters

Stripe takes form fields, not JSON. `TStripeParams` keeps them in the
order they were added and encodes both sides:

```pascal
P := Default(TStripeParams);
P.Add('line_items[0][price]', 'price_1');      { nested, as Stripe writes it }
P.Add('line_items[0][quantity]', 2);           { an Int64 }
P.AddBool('allow_promotion_codes', True);      { true or false }
P.Add('metadata[order_id]', '1042');
```

It is a record with no heap object inside it that needs freeing; start it
with `Default(TStripeParams)`.

## Errors

`EStripeError` is Stripe's error, as Stripe wrote it:

| | |
|---|---|
| `E.Status` | The HTTP status; 0 when the request never reached Stripe |
| `E.Type_` | Stripe's type: `card_error`, `invalid_request_error`, `api_error`, `idempotency_error` — or `config` and `network`, which are the plugin's |
| `E.Code` | Stripe's code: `card_declined`, `resource_missing`, ... |
| `E.DeclineCode` | For a card: `insufficient_funds`, ... |
| `E.Param` | The parameter Stripe objected to |
| `E.RequestId` | Stripe's request id — what its dashboard finds the request by |
| `E.Retryable` | Whether sending it again can help |
| `E.Message` | Stripe's message, with the type and code after it |

**`Retryable` is the one a queue job needs.** It follows Stripe's own
`Stripe-Should-Retry` header when Stripe sends one, as Stripe's libraries
do. Without it: a 409 (a concurrent request with the same key), a 429 and
any 5xx are worth another try, and a network failure is too; a declined
card or a bad parameter never becomes more correct by being sent again.

```pascal
try
  Stripe.Post('/v1/invoiceitems', P, 'setup-fee-' + OrderId);
except
  on E: EStripeError do
    if E.Retryable then
      raise              { the queue tries again }
    else
      RecordFailure(OrderId, E.Message);
end;
```

**The secret is never in an error, a log line or `Describe`.** Neither is
the body of a reply that is not Stripe's JSON — a proxy's error page —
which comes through as its status alone.

## Idempotency

Every POST carries an `Idempotency-Key`. Without one of yours it is a
random key, which is what Stripe's own libraries send, and it makes a
request sent twice by accident — a network hiccup — count once.

**Only your own key covers a retry.** A queue job that fails after Stripe
took its request runs again, and a new random key is a new request. Give
it a key that is the same every time the job runs, and different for
every job:

```pascal
Stripe.Post('/v1/invoiceitems', P, 'setup-fee-' + OrderId);
```

Stripe keeps a key for 24 hours, across everything that shares the
account, and answers the same request with the same key with its first
reply. The same key with a different body is refused. So a key is made
of what identifies the *attempt* — an order, a job — and never of
something another app on the same account also has, like a user id.

## The API version

Every request carries `Stripe-Version: 2026-08-26.dahlia`,
`StripeApiVersion` in `Askr.Plugin.Stripe.Client`. Without it, the
account's default version would decide the shape of every reply, and that
default moves when someone clicks a button in the dashboard.

A webhook's payload follows the endpoint's version instead, which is why
the endpoint has to be created with the same one. Where Stripe has moved
a field between versions and the plugin reads it — the period end moved
from the subscription to its items in 2025-03-31, an invoice's
subscription under `parent` — it reads both places.

## Reference

| Unit | |
|---|---|
| `Askr.Plugin.Stripe` | The plugin, the webhook route, `RequireSubscribed`, `SetStripeWebhookSecret` |
| `Askr.Plugin.Stripe.Billing` | Customers, Checkout, the portal, subscriptions, the events |
| `Askr.Plugin.Stripe.Client` | `TStripeClient`, `TStripeParams`, `EStripeError`, `StripeField`, the HTTP layer and its fake |
| `Askr.Plugin.Stripe.Signature` | `VerifyStripeSignature`, `StripeSignatureHeader` |
