# Subscriptions

A subscription is made on Stripe's Checkout page, lives in Stripe, and is
copied into `stripe_subscriptions` by the webhook each time it changes.
Your app asks the copy.

## Starting one with Checkout

```pascal
uses Askr.Plugin.Stripe.Billing;

function Subscribe(Req: TRequest): TResponse;
var
  C: TCheckout;
begin
  C := SubscriptionCheckout('price_pro_monthly',
    AppUrl + '/billing/thanks',    { after paying }
    AppUrl + '/pricing');          { the back link on Checkout }
  Result := Redirect(CheckoutUrl(Askr.Auth.Id, UserEmail, C), 303);
end;
```

`CheckoutUrl` makes the user's Stripe customer if there is none, makes a
Checkout session for them, and returns the page to send them to. The
session carries the user id as `client_reference_id` and in the
subscription's metadata, so the subscription it makes can always be found
again.

`TCheckout` is a record: set its fields before `CheckoutUrl`.

| Field | |
|---|---|
| `C.Add(Price, Quantity)` | Another price on the same subscription — a base plan and seats, say |
| `C.TrialDays` | A trial of that many days before the first charge |
| `C.AllowPromotionCodes` | Shows Stripe's promotion code field on the page |
| `C.IdempotencyKey` | A retry with the same key returns the same session instead of a second one |
| `C.Extra` | Anything else Checkout takes, in Stripe's names |

### Several prices and quantities

```pascal
C := SubscriptionCheckout('price_team_base', OkUrl, BackUrl);
C.Add('price_team_seat', Seats);
```

Each price becomes an item on one subscription, and every one is in
`stripe_subscription_items` — `Subscribed(User, 'price_team_seat')` is
true as well as `Subscribed(User, 'price_team_base')`.

### Trials

```pascal
C.TrialDays := 14;
```

Checkout takes a card up front and charges nothing until the trial ends.
To start a trial without asking for a card, add Stripe's own parameter:

```pascal
C.TrialDays := 14;
C.Extra.Add('payment_method_collection', 'if_required');
```

A trial without a card ends in `past_due` or cancelled when it runs out,
depending on the subscription's settings in the dashboard; Stripe emails
the customer to add one if you have turned that on.

A trial belongs to a subscription. `TrialDays` on a payment checkout
raises before anything is sent.

### Anything else

`C.Extra` takes any parameter Stripe's
[Checkout reference](https://docs.stripe.com/api/checkout/sessions/create)
lists, and sends it after the fields above:

```pascal
C.Extra.Add('billing_address_collection', 'required');
C.Extra.Add('subscription_data[description]', 'Pro plan');
C.Extra.Add('locale', 'nb');
```

The plugin has fields only for what most apps set. A field for each of
Checkout's parameters would be a second copy of Stripe's reference, and it
would always be behind it.

## Checking a subscription

| | |
|---|---|
| `Subscribed(UserId)` | A subscription that is active or trialing |
| `Subscribed(UserId, Price)` | ... with that price among its items |
| `OnTrial(UserId)` | Trialing, and the trial has not ended |
| `OnGracePeriod(UserId)` | Cancelled, and still running to the end of what was paid for |
| `FindSubscription(UserId, S)` | The subscription itself |

```pascal
var
  S: TStripeSubscription;
begin
  if FindSubscription(Askr.Auth.Id, S) then
    { S.StripeId, S.Status, S.Price, S.Prices, S.ItemIds, S.Quantity,
      S.TrialEnd, S.CurrentPeriodEnd, S.CancelAtPeriodEnd, S.CancelAt,
      S.EndedAt, S.Valid }
end;
```

`FindSubscription` gives the user's valid subscription if there is one,
and otherwise the newest. The times are Stripe's unix seconds, and 0 means
none.

What each of Stripe's statuses means here:

| Status | `Subscribed` | |
|---|---|---|
| `trialing` | yes | In a trial. `OnTrial` is true until `TrialEnd` |
| `active` | yes | Paid. Also through the grace period after cancelling |
| `past_due` | no | A renewal failed and Stripe is retrying it |
| `incomplete` | no | The first payment failed or needs 3-D Secure |
| `incomplete_expired` | no | ... and was not completed within 23 hours |
| `unpaid` | no | Stripe gave up retrying |
| `canceled` | no | Ended |
| `paused` | no | A trial ended without a card, set to pause |

`past_due` locks a user out at once. Whether it should is your decision:
many apps keep access for the days Stripe retries. Ask for it yourself:

```pascal
Paid := Subscribed(Id) or (FindSubscription(Id, S) and (S.Status = 'past_due'));
```

**The row's own times answer when a webhook is late.** A trial whose end
has passed is not a trial, and a grace period whose end has passed is
not a grace period, even before the webhook that ends them arrives.

## Pages for subscribers

A router's middleware covers every route, so a paid page asks for itself,
the way a page that needs a verified address does:

```pascal
function Reports(Req: TRequest): TResponse;
begin
  Result := RequireSubscribed('price_pro_monthly', '/pricing');
  if Result <> nil then
    Exit;
  Result := RespondHtml(RenderReports);
end;
```

`RequireSubscribed(Price, PricingPath)` is `nil` when the signed-in user
has a valid subscription — to that price, when one is given — and
otherwise the answer to send:

| Client | Answer |
|---|---|
| A browser | `303` to `PricingPath`, `/pricing` unless given |
| An Inertia visit | `409` with `X-Inertia-Location`, which Inertia follows as a full visit |
| A JSON client | `402` with a problem document |

**Nobody signed in is refused too.** `RequireVerified` leaves that case to
`RequireAuth`; this does not, because a paid page that opened because
someone forgot `RequireAuth` is a paid page given away.

## Cancelling

```pascal
CancelSubscription(UserId);       { at the end of the paid period }
ResumeSubscription(UserId);       { take that back, while it still runs }
CancelSubscriptionNow(UserId);    { end it now }
```

`CancelSubscription` sets `cancel_at_period_end`: the user keeps what they
paid for, `Subscribed` stays true and `OnGracePeriod` becomes true, and
when the period ends Stripe ends the subscription and the webhook marks
it `canceled`. `ResumeSubscription` takes the cancellation back as long
as the period has not ended. `CancelSubscriptionNow` ends it at once,
and by default Stripe neither refunds nor credits the unused part of the
period — a refund is yours to make, in the dashboard or through the API.

Each applies Stripe's reply to your table straight away, so the next page
shows the change; the webhook for the same change arrives a moment later
and changes nothing further. Each raises an `EStripeError` when the user
has no valid subscription, before asking Stripe.

The portal can do all three, when it is allowed in its settings, and
most apps let it.

## Changing a plan

Moving a subscriber from one price to another is the portal's, in 0.1:
turn on "Customers can switch plans" in the portal settings and list the
prices they may switch between. The plan change comes back as
`customer.subscription.updated`, and `Subscribed(User, NewPrice)` is true
from then.

From code, it is Stripe's API. Stripe changes an item by its `si_...` id,
and `S.ItemIds` has them, in the same order as `S.Prices`:

```pascal
var
  S: TStripeSubscription;
  P: TStripeParams;
begin
  if not FindSubscription(UserId, S) or not S.Valid then
    Exit;
  P := Default(TStripeParams);
  P.Add('items[0][id]', S.ItemIds[0]);
  P.Add('items[0][price]', 'price_pro_yearly');
  P.Add('proration_behavior', 'create_prorations');
  Stripe.Post('/v1/subscriptions/' + S.StripeId, P);
end;
```

The table changes when the webhook for it arrives, a moment later.

A `SwapPrice` of the plugin's own is the obvious next function, and not
in 0.1: which proration an app wants is a question with several right
answers, and a helper that picks one would be wrong for the others.
