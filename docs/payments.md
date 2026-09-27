# Payments

A one-off payment — a book, a pack of credits, a lifetime licence — is
Checkout in payment mode. A renewal that fails is Stripe's to retry and
yours to tell the user about.

## A one-off payment

```pascal
uses Askr.Plugin.Stripe.Billing;

function BuyCredits(Req: TRequest): TResponse;
begin
  Result := Redirect(CheckoutUrl(Askr.Auth.Id, UserEmail,
    PaymentCheckout('price_credits_100', 1,
      AppUrl + '/credits/thanks', AppUrl + '/credits')), 303);
end;
```

`PaymentCheckout(Price, Quantity, SuccessUrl, CancelUrl)` takes a price
that is **not** recurring; Stripe refuses a recurring price in payment
mode. More lines go on with `C.Add`, and anything else Checkout takes goes
in `C.Extra` — a receipt as an invoice, for instance:

```pascal
C := PaymentCheckout('price_book', 1, OkUrl, BackUrl);
C.Add('price_gift_wrap', 1);
C.Extra.Add('invoice_creation[enabled]', 'true');
```

## Fulfilling an order

The success page is where the user lands, not proof of anything. The
payment is told by a webhook:

```pascal
procedure FulfilCredits(E: TEvent);
var
  P: TStripePaymentSucceeded;
begin
  P := TStripePaymentSucceeded(E);
  { P.UserId, P.SessionId, P.PaymentIntent, P.AmountTotal, P.Currency }
  GrantCredits(P.UserId, 100, P.SessionId);
end;

Listen(TStripePaymentSucceeded, @FulfilCredits);
```

It is dispatched once per payment, **when it is paid**: for a card that is
`checkout.session.completed`, and for a bank debit, which completes the
session unpaid and settles days later, it is
`checkout.session.async_payment_succeeded`. A subscription checkout is not
a payment here; its events are the subscription's own.

`AmountTotal` is in minor units, as Stripe counts: 12900 is 129.00. Into
`Currency` by assignment, never by a cast — a cast reinterprets the bits
instead of converting the value, and gives a different answer on x86_64
than on arm64:

```pascal
var
  Amount: Currency;
begin
  Amount := P.AmountTotal;
  Amount := Amount / 100;
end;
```

**Key what you grant by the session id.** The webhook is recorded once, so
`FulfilCredits` runs once — but it runs inside the webhook's transaction, and a
listener that sends mail and then fails leaves the mail sent and the event
unrecorded, and Stripe's retry sends it again. Work with an effect outside
your database belongs in the queue, keyed by the session:

```pascal
ListenQueued(Queue, TStripePaymentSucceeded, 'shop.fulfil', @FulfilCredits);
```

and a mail sent from it carries `Idempotency(P.SessionId)`.

## When a payment fails

**At Checkout**, a declined card is the page's problem: Stripe shows the
decline and asks for another card, and nothing reaches your app until a
payment goes through. 3-D Secure happens on the page too.

**At renewal**, Stripe charges the saved card. If it is declined, the
subscription becomes `past_due`, Stripe retries by the schedule in your
dashboard's Smart Retries settings, and the plugin dispatches
`TStripePaymentFailed` for each failed attempt:

```pascal
procedure Dunning(E: TEvent);
var
  F: TStripePaymentFailed;
begin
  F := TStripePaymentFailed(E);
  Mail.Send(Mail.Message_
    .AddTo(EmailOf(F.UserId))
    .Subject('Your payment did not go through')
    .Text('Update your card: ' + AppUrl + '/billing')
    .Idempotency(F.InvoiceId));
end;

ListenQueued(Queue, TStripePaymentFailed, 'billing.dunning', @Dunning);
```

`/billing` is the route that sends the user to the portal. If every
retry fails, the subscription ends up `canceled` or `unpaid`, as the
dashboard says, and the webhook marks it so.

`Subscribed` is false for `past_due`. See
[checking a subscription](subscriptions.md) for keeping access while
Stripe retries.

## 3-D Secure on a renewal

A bank can ask for authentication on a renewal the customer is not there
for. Stripe handles this without your code: with "Send a Stripe-hosted
link for customers to confirm their payments" on in the dashboard's
subscription settings, Stripe emails the customer a page to confirm on.
Until they do, the subscription is `past_due` and
`invoice.payment_action_required` arrives as a `TStripeEventReceived`.

## Refunds

A refund is Stripe's API, by the payment intent the event gave you:

```pascal
var
  P: TStripeParams;
begin
  P := Default(TStripeParams);
  P.Add('payment_intent', PaymentIntent);
  Stripe.Post('/v1/refunds', P);
end;
```

It arrives back as `charge.refunded`, which you can listen for through
`TStripeEventReceived` — see [webhooks](webhooks.md).
