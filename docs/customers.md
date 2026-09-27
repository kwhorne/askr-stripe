# Customers

Everything in Stripe that belongs to someone belongs to a customer:
subscriptions, invoices, payment methods. The plugin keeps one Stripe
customer per user of your app.

## A customer per user

The framework does not own your user model, so the customer is keyed by
the user id as text — the id `Login` takes and `Askr.Auth.Id` gives
back, the same key API tokens use.

```pascal
uses Askr.Plugin.Stripe.Billing;

Customer := EnsureStripeCustomer(Askr.Auth.Id, Email, Name);
```

The first call makes the customer in Stripe and keeps its id in
`stripe_customers`; every later call reads the row and sends nothing.
The email and name are what Stripe shows in the dashboard and puts on
receipts. The customer also carries the user id in its metadata, as
`askr_user_id`, which is the way back from Stripe's side: it is what the
dashboard shows you, and what a webhook about a customer your app did not
make is matched by.

You rarely call it yourself. `CheckoutUrl` does, before every checkout.

| | |
|---|---|
| `EnsureStripeCustomer(UserId, Email, Name)` | The customer's id, made the first time |
| `StripeCustomerId(UserId)` | The customer's id, or `''` when the user has none |

**Two requests at once make one customer in your table.** Two tabs can
both reach Checkout before either has a row, and both make a customer in
Stripe. The unique index on `stripe_customers` decides: the first row
stays, and the request that lost deletes the customer it made, so the
account does not collect customers nothing points at.

An earlier version used the user id as the request's idempotency key.
Stripe keeps a key for a day across everything that shares the account,
and the first run against a real account found what that means: a
database that had been reset got a deleted customer back, and two apps on
one account — a dev and a staging — would have shared customers. The
key is random now.

## Updating a customer

Changes to a customer — a new email, an address for receipts — go to
Stripe directly. The plugin keeps only the id, so there is nothing in
your tables to keep in step:

```pascal
var
  P: TStripeParams;
begin
  P := Default(TStripeParams);
  P.Add('email', NewEmail);
  P.Add('address[country]', 'NO');
  Stripe.Post('/v1/customers/' + StripeCustomerId(UserId), P);
end;
```

See [the Stripe API](api.md) for `Stripe.Post` and its errors. A
customer changed in the portal or the dashboard needs nothing from you.

## The billing portal

Stripe's customer portal is a page where a customer updates a card,
downloads an invoice, changes a plan or cancels — whatever you allow in
the dashboard, under Settings > Billing > Customer portal.

```pascal
function Billing(Req: TRequest): TResponse;
begin
  Result := Redirect(BillingPortalUrl(Askr.Auth.Id,
    AppUrl + '/account'), 303);
end;
```

The return url is where the portal's back link goes. Anything the
customer does there comes back as webhooks, so your tables follow
without a line of code.

`BillingPortalUrl` raises an `EStripeError` when the user has no customer
yet — somebody who has never been to Checkout has nothing to manage. Show
them the pricing page instead:

```pascal
if StripeCustomerId(Askr.Auth.Id) = '' then
  Exit(Redirect('/pricing', 303));
```

In test mode the portal needs its settings saved once in the dashboard
too; until then Stripe answers that no configuration exists, and that is
the message the exception carries.

## Deleting a customer

```pascal
Stripe.Delete('/v1/customers/' + StripeCustomerId(UserId));
```

Deleting a customer in Stripe cancels its subscriptions at once; the
webhooks that follow mark them ended in your tables. The row in
`stripe_customers` stays, pointing at a deleted customer — delete it
yourself if the user is going too, which is the common reason.
