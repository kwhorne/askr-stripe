# Testing

An app's billing can be tested without Stripe: the HTTP layer has a fake,
the webhook takes a header the test signs itself, and the events can be
recorded instead of delivered.

## Setting up

```pascal
uses
  Askr.Testing, Askr.Http.Router, Askr.Core.Clock, Askr.Urd.Model,
  Askr.Norn.Migration, Askr.Events,
  Askr.Plugin.Stripe, Askr.Plugin.Stripe.Client,
  Askr.Plugin.Stripe.Billing, Askr.Plugin.Stripe.Signature;

var
  Fake: TFakeStripeHttp;

procedure Fresh;
var
  M: TMigrator;
  C: TStripeClient;
begin
  UseTestDatabase;                   { sqlite::memory:, the plugin's tables }
  M := TMigrator.Create(CurrentDb);
  try
    M.Up;
  finally
    M.Free;
  end;

  Fake.Free;
  Fake := TFakeStripeHttp.Create;
  C := TStripeClient.Create('sk_test_suite');
  C.UseHttp(Fake, False);            { the test keeps the fake }
  SetStripe(C);                      { the client every call goes through }
  SetStripeWebhookSecret('whsec_suite');
end;
```

## What the app sends

`Fake.Queue(Json, Status)` sets the reply to the next request, and
`Fake.Last` is what was sent: `Method`, `Url`, `Form`, `IdempotencyKey`.

```pascal
procedure TestCheckout;
var
  Url: string;
begin
  Fresh;
  Fake.Queue('{"id":"cus_1"}');                      { the customer }
  Fake.Queue('{"id":"cs_1","url":"https://checkout.stripe.com/c/pay/cs_1"}');
  Url := CheckoutUrl('7', 'ada@example.com',
    SubscriptionCheckout('price_pro', 'https://x/ok', 'https://x/no'));
  AssertEqual(Url, 'https://checkout.stripe.com/c/pay/cs_1', 'the page');
  AssertContains(Fake.Last.Form, 'mode=subscription', 'a subscription');
end;
```

A request with no reply queued raises, so a test cannot pass by sending
more than it meant to.

## A webhook of your own

Post an event through the real route, signed with the test's secret, and
the plugin does exactly what it does with Stripe's:

```pascal
procedure TestWelcome;
var
  R: TRouter;
  C: TTestClient;
  Body: string;
begin
  Fresh;
  FakeEvents([]);                    { record, don't deliver }
  Fake.Queue('{"id":"cus_A"}');
  EnsureStripeCustomer('7', 'ada@example.com');   { user 7 is cus_A }
  Body := '{"id":"evt_1","object":"event","created":' + IntToStr(UnixNow) +
    ',"type":"customer.subscription.created","data":{"object":' +
    '{"id":"sub_1","object":"subscription","customer":"cus_A",' +
    '"status":"active","items":{"data":[{"id":"si_1",' +
    '"price":{"id":"price_pro"},"quantity":1}]}}}}';

  R := TRouter.Create;
  R.Post('/stripe/webhook', StripeWebhook);   { the plugin's own handler }
  C := TTestClient.Create(R);
  try
    AssertStatus(C.WithHeader('Stripe-Signature',
        StripeSignatureHeader(Body, 'whsec_suite', UnixNow))
      .Post('/stripe/webhook', Body), 200, 'taken');
  finally
    C.Free;
    R.Free;
  end;
  AssertTrue(Subscribed('7', 'price_pro'), 'subscribed');
  AssertEqual(EventsDispatched(TStripeSubscriptionCreated), 1, 'told once');
end;
```

`FakeEvents([])` records every event instead of running its listeners;
`EventsDispatched` counts them and `DispatchedEventJson` gives one's
fields. Leave it out, and your real listeners run — which is how to test
them.

## Against stripe-mock

[stripe-mock](https://github.com/stripe/stripe-mock) is Stripe's own
server built from its OpenAPI spec. It answers every endpoint with a
fixture and refuses a top-level parameter Stripe does not have:

```sh
docker run --rm -p 12111:12111 stripe/stripe-mock
```

```pascal
SetStripe(TStripeClient.Create('sk_test_mock', 'http://localhost:12111'));
```

In a test the plugin's `Configure` does not run, so the client is made by
hand; in a running app, `STRIPE_BASE_URL` does the same.

It does not check keys nested inside a parameter, like
`line_items[0][price]`, and it keeps nothing: a customer made there is not
there when you ask for it. It proves the shape of a request, not what
Stripe would do with it.

## What the plugin itself is held to

The plugin's repository runs four checks, each for what the others
cannot see:

| | |
|---|---|
| `./check` | The suite: the signature check held to stripe-python's verdict on thirty headers, every request held to stripe-mock, the headers read off a raw socket, and the webhook's order, duplicates and rollback |
| `./check --checks` | The same with range, overflow and I/O checks |
| `./check --app` | A new `askr new --auth` app: the plugin added from a tag, built, migrated, and a signed webhook over HTTP through sessions, the rate limit and CSRF |
| `STRIPE_SECRET=sk_test_... ./check --testmode` | A real test-mode account, with `stripe listen` forwarding its own events |

The last is run by hand, with a test key: it makes and deletes customers,
a product and subscriptions in the account. It has been run, and it found
a bug the other three could not — the customer's idempotency key, in
[customers](customers.md). What none of them prove is live mode, a real
card, or a Checkout page completed by a person.
