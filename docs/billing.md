# Getting started

askr-stripe gives an Askr app what it needs to take money through Stripe:
a Stripe customer for each user, Checkout for subscriptions and one-off
payments, the customer portal, questions like "is this user subscribed",
and a webhook that keeps the app's copy of all of it in step with Stripe.

It is a plugin, not part of the framework. Billing is not something every
app needs, and Stripe changes on Stripe's schedule rather than Askr's. It
builds against Askr 0.16 and later.

**What the plugin never sees is a card.** Checkout and the portal are
Stripe's own pages. The card, 3-D Secure and strong customer
authentication happen there, so none of it is Pascal your app has to
trust, and none of it brings your app into PCI scope.

## Installation

```sh
askr plugin add https://github.com/kwhorne/askr-stripe.git
askr migrate
```

`plugin add` fetches the newest release, writes `[plugins.stripe]` into
askr.toml and the commit into askr.lock, and adds the two lines that start
plugins to app.lpr if they are not there. `askr migrate` makes the
plugin's four tables, recorded under `stripe:` in `askr_migrations`.

A plugin is compiled into your binary and can do anything your app can.
Read what you add; the commit in askr.lock is what you read.

## Configuration

```sh
# .env
STRIPE_SECRET=sk_test_...
STRIPE_WEBHOOK_SECRET=whsec_...
```

| Setting | |
|---|---|
| `STRIPE_SECRET` | The secret key, `sk_test_...` or `sk_live_...`, from Developers > API keys |
| `STRIPE_WEBHOOK_SECRET` | The webhook endpoint's signing secret, `whsec_...` — see [webhooks](webhooks.md) |
| `STRIPE_WEBHOOK_PATH` | Where the webhook answers; `/stripe/webhook` unless set |
| `STRIPE_WEBHOOK_TOLERANCE` | How many seconds a signature stays good; 300 |
| `STRIPE_BASE_URL` | `https://api.stripe.com` unless set; stripe-mock in tests |

Each is read through Askr's configuration, so a real environment variable
wins over `.env`, and `.env` over askr.toml, where the same keys are
`stripe.secret`, `stripe.webhook.secret` and so on.

**A missing secret does not stop the app.** It is logged when the app
starts, and every call to Stripe raises an `EStripeError` that names the
variable. An app has to be able to run its migrations and its own tests
before it has a Stripe account. **A missing webhook secret refuses every
webhook** with a 500, rather than taking them unverified; Stripe sends
them again once it is set.

The plugin pins Stripe's API version to `2026-08-26.dahlia` and sends it
with every request. Create the webhook endpoint with the same version —
[webhooks](webhooks.md) says why.

## Quickstart: selling a subscription

Make a product with a monthly price in the Stripe dashboard, and copy the
price's id, `price_...`. Then three pieces of code: a route that sends the
user to Checkout, a page that asks whether they are subscribed, and a
listener that hears when they became it.

```pascal
uses
  Askr.Auth, Askr.Http.Request, Askr.Http.Response, Askr.Events,
  Askr.Plugin.Stripe, Askr.Plugin.Stripe.Billing;

const
  ProMonthly = 'price_1Q...';

{ POST /subscribe: to Stripe's Checkout page. }
function Subscribe(Req: TRequest): TResponse;
var
  C: TCheckout;
begin
  C := SubscriptionCheckout(ProMonthly,
    AppUrl + '/billing/thanks', AppUrl + '/pricing');
  C.TrialDays := 14;
  Result := Redirect(CheckoutUrl(Askr.Auth.Id, UserEmail, C), 303);
end;

{ GET /reports: only for subscribers. }
function Reports(Req: TRequest): TResponse;
begin
  Result := RequireSubscribed(ProMonthly);
  if Result <> nil then
    Exit;
  Result := RespondHtml(RenderReports);
end;

{ Stripe's webhook said so. This is where access is granted -- not on the
  thanks page, which anyone can open. }
procedure Welcome(E: TEvent);
begin
  SendWelcomeMail(TStripeSubscriptionCreated(E).UserId);
end;
```

```pascal
{ app.lpr, after UsePlugins(R): }
R.Post('/subscribe', @Subscribe);
R.Get('/reports', @Reports);
Listen(TStripeSubscriptionCreated, @Welcome);
```

`AppUrl`, `UserEmail`, `RenderReports` and `SendWelcomeMail` are your
app's. The thanks page is where the user lands after paying. **It is not
proof of payment**: a user can close the tab before it loads, and anyone
can type its address. What happened arrives as a webhook, and by the time
most users see the thanks page it has.

## Quickstart: selling a product

A one-off payment is Checkout in payment mode, with a price that is not
recurring:

```pascal
function BuyBook(Req: TRequest): TResponse;
begin
  Result := Redirect(CheckoutUrl(Askr.Auth.Id, UserEmail,
    PaymentCheckout('price_book', 1,
      AppUrl + '/shop/thanks', AppUrl + '/shop')), 303);
end;

procedure Fulfil(E: TEvent);
var
  P: TStripePaymentSucceeded;
begin
  P := TStripePaymentSucceeded(E);
  ShipBook(P.UserId, P.SessionId);
end;

Listen(TStripePaymentSucceeded, @Fulfil);
```

`TStripePaymentSucceeded` comes when the payment is paid, not when the
Checkout session completes: a bank debit completes unpaid and settles days
later. See [payments](payments.md).

## The tables

| Table | |
|---|---|
| `stripe_customers` | A user id and their Stripe customer |
| `stripe_subscriptions` | Each subscription as Stripe last described it |
| `stripe_subscription_items` | Its prices and quantities |
| `stripe_events` | Every webhook event's id, once |

They hold what Stripe said, never what the app asked for: a checkout, a
cancel or a resume sends the request, and the row follows Stripe's reply
or its webhook. Times are Stripe's unix seconds, in columns named as
Stripe names them.

## What is not here

askr-stripe 0.1 is Checkout, the portal and subscriptions. Next to
Laravel Cashier, which this is modelled on, these are not in it:

- **Payment methods in your own pages** — storing cards, listing them,
  charging one directly. Checkout and the portal do this on Stripe's
  pages; doing it in yours brings the card into your app.
- **Changing a plan or a quantity from code.** The portal does it, when
  it is allowed in the dashboard's portal settings. From code, it is the
  raw API: see [the Stripe API](api.md).
- **Invoices as PDF, upcoming invoices**, metered and usage-based billing,
  Stripe Tax, tax IDs, customer balances, and Connect. Each is a Stripe
  product with its own surface, and none of them is needed to take a
  subscription.
- **Several subscriptions per user by name.** A user can have more than
  one subscription, and `Subscribed(User, Price)` asks about any of them;
  there is no `'default'`/`'swimming'` naming as in Cashier.
- **Guest checkout.** Every Checkout here has a customer, and every
  customer a user.
