{ One run against a real Stripe account in test mode.

  ./check --testmode runs it, inside a new app that is serving, with
  `stripe listen` forwarding the account's real events -- signed by Stripe
  -- to the app's /stripe/webhook. This program drives the account through
  the plugin's own functions and waits for what the webhooks write.

  It is an example and not a test: a suite that only people with a Stripe
  account can run is a suite most people cannot run. The same reason as
  the framework's examples/ai/aiprobe.lpr.

  It makes a product, two customers and three subscriptions in the test
  account, ends the subscriptions, deletes the customers and archives the
  product. The secret key is read from STRIPE_SECRET and never printed. }
program TestMode;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, Classes,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json, Askr.Core.Clock,
  Askr.Core.Log, Askr.Urd.Driver, Askr.Urd.Model, Askr.Urd.Sqlite,
  Askr.Plugin.Stripe.Client, Askr.Plugin.Stripe.Billing;

var
  Failures: Integer = 0;
  Db: TDbConnection;

procedure Ok(const What: string);
begin
  WriteLn('  ok    ', What);
end;

procedure Bad(const What, Why: string);
begin
  WriteLn('  FAIL  ', What);
  if Why <> '' then
    WriteLn('        ', Why);
  Inc(Failures);
end;

procedure Check(Cond: Boolean; const What: string; const Why: string = '');
begin
  if Cond then
    Ok(What)
  else
    Bad(What, Why);
end;

{ A field by path: 'parent.subscription_details.subscription'. }
function Field(const Json, Path: string): string;
var
  A: TArena;
  V: PJsonValue;
  ErrPos: SizeInt;
  Parts: TStringArray;
  I: Integer;
begin
  Result := '';
  A := TArena.Create(Length(Json) * 4 + 16 * 1024);
  try
    if not JsonParse(A, Str(Json), V, ErrPos) then
      Exit;
    Parts := Path.Split(['.']);
    for I := 0 to High(Parts) do
      V := JsonMember(V, Parts[I]);
    Result := JsonAsString(V);
  finally
    A.Free;
  end;
end;

function Rows(const Sql: string): Int64;
var
  A: TArena;
begin
  A := TArena.Create(4096);
  try
    Result := Db.Exec(A, Sql).AsInt64(0, 0);
  finally
    A.Free;
  end;
end;

function EventSeen(const EventType, ObjectPrefix: string): Boolean;
begin
  { Recorded by the app, in the same file, when Stripe's webhook came. }
  Result := Rows('SELECT count(*) FROM stripe_events WHERE type = ''' +
    EventType + '''') > 0;
end;

type
  TCond = function: Boolean;

var
  GUser, GPrice, GType: string;

function CondSubscribed: Boolean;
begin
  Result := Subscribed(GUser, GPrice);
end;

function CondEvent: Boolean;
begin
  Result := EventSeen(GType, '');
end;

function CondTrial: Boolean;
begin
  Result := OnTrial(GUser);
end;

function CondEnded: Boolean;
var
  S: TStripeSubscription;
begin
  Result := FindSubscription(GUser, S) and (S.Status = 'canceled') and
    EventSeen('customer.subscription.deleted', '');
end;

{ Webhooks take a moment: Stripe, then the CLI, then the app. }
function WaitFor(C: TCond; Seconds: Integer = 45): Boolean;
var
  Until_: Int64;
begin
  Until_ := UnixNowMs + Seconds * 1000;
  repeat
    if C() then
      Exit(True);
    Sleep(500);
  until UnixNowMs > Until_;
  Result := False;
end;

function Post(const Path: string; const P: TStripeParams): string;
begin
  Result := Stripe.Post(Path, P);
end;

var
  P: TStripeParams;
  Price, Product, Cust7, Cust8, Sub7, Sub8, Sub9, Reply, Url, Invoice: string;
  S: TStripeSubscription;
  Secret: string;
begin
  Secret := GetEnvironmentVariable('STRIPE_SECRET');
  if Copy(Secret, 1, 8) <> 'sk_test_' then
  begin
    WriteLn('STRIPE_SECRET must be a test-mode key, sk_test_...: this run ',
      'makes and deletes things in the account.');
    Halt(2);
  end;
  SetLogLevel(llError);
  Db := OpenDbConnection(GetEnvironmentVariable('DATABASE_URL'));
  UseDb(Db);
  SetStripe(TStripeClient.Create(Secret));
  Secret := '';
  WriteLn('Stripe test mode, API version ', StripeApiVersion);

  try
    { --- a price to subscribe to -------------------------------------- }
    P := Default(TStripeParams);
    P.Add('currency', 'nok');
    P.Add('unit_amount', 9900);
    P.Add('recurring[interval]', 'month');
    P.Add('product_data[name]', 'askr-stripe test mode run');
    Reply := Post('/v1/prices', P);
    Price := Field(Reply, 'id');
    Product := Field(Reply, 'product');
    Check(Copy(Price, 1, 6) = 'price_', 'a monthly price of 99.00 NOK', Reply);
    GPrice := Price;

    { --- a customer, once --------------------------------------------- }
    Cust7 := EnsureStripeCustomer('7', 'askr-testmode-7@example.com', 'Test Seven');
    Check(Copy(Cust7, 1, 4) = 'cus_', 'EnsureStripeCustomer made a customer');
    Check(EnsureStripeCustomer('7', 'askr-testmode-7@example.com') = Cust7,
      'and the second call read it');
    Check(Field(Stripe.Get('/v1/customers/' + Cust7), 'metadata.askr_user_id') = '7',
      'the customer carries askr_user_id in Stripe');

    { --- Checkout and the portal -------------------------------------- }
    Url := CheckoutUrl('7', '', SubscriptionCheckout(Price,
      'https://example.com/ok', 'https://example.com/no'));
    Check(Pos('https://checkout.stripe.com/', Url) = 1,
      'a subscription Checkout session', Url);
    Url := CheckoutUrl('7', '', PaymentCheckout(Price, 1,
      'https://example.com/ok', 'https://example.com/no'));
    Check(Url = '', 'a payment Checkout with a recurring price is refused ' +
      'by Stripe', 'got ' + Url);
  except
    on E: EStripeError do
      if Pos('recurring', E.Message) > 0 then
        Ok('a payment Checkout with a recurring price is refused by Stripe: ' +
          E.Type_)
      else
        Bad('Checkout', E.Message);
  end;

  try
    Url := BillingPortalUrl('7', 'https://example.com/account');
    Check(Pos('https://billing.stripe.com/', Url) = 1, 'the customer portal', Url);
  except
    on E: EStripeError do
      { The portal needs its settings saved once in the dashboard, in test
        mode too. Stripe's answer is what this reports. }
      WriteLn('  note  the customer portal: ', E.Message);
  end;

  try
    { --- a subscription, paid by a test card -------------------------- }
    P := Default(TStripeParams);
    P.Add('customer', Cust7);
    Reply := Post('/v1/payment_methods/pm_card_visa/attach', P);
    P := Default(TStripeParams);
    P.Add('invoice_settings[default_payment_method]', Field(Reply, 'id'));
    Post('/v1/customers/' + Cust7, P);
    P := Default(TStripeParams);
    P.Add('customer', Cust7);
    P.Add('items[0][price]', Price);
    Reply := Post('/v1/subscriptions', P);
    Sub7 := Field(Reply, 'id');
    Check(Field(Reply, 'status') = 'active', 'a subscription paid by 4242...',
      Field(Reply, 'status'));

    GUser := '7';
    Check(WaitFor(@CondSubscribed),
      'Stripe''s webhook arrived, verified, and the user is subscribed');
    GType := 'invoice.paid';
    WaitFor(@CondEvent, 15);
    Check(FindSubscription('7', S) and (S.CurrentPeriodEnd > UnixNow + 20 * 86400),
      'the period end, read off the subscription item',
      IntToStr(S.CurrentPeriodEnd));

    { --- cancel, resume, end ------------------------------------------ }
    CancelSubscription('7');
    Check(OnGracePeriod('7'), 'cancelled at the period''s end: a grace period, at once');
    Check(Subscribed('7', Price), 'still subscribed through it');
    ResumeSubscription('7');
    Check(not OnGracePeriod('7'), 'resumed');
    CancelSubscriptionNow('7');
    Check(WaitFor(@CondEnded), 'ended now, and customer.subscription.deleted arrived');
    Check(not Subscribed('7'), 'no longer subscribed');

    { --- a trial ------------------------------------------------------ }
    P := Default(TStripeParams);
    P.Add('customer', Cust7);
    P.Add('items[0][price]', Price);
    P.Add('trial_period_days', 7);
    Sub9 := Field(Post('/v1/subscriptions', P), 'id');
    Check(WaitFor(@CondTrial), 'a seven-day trial arrived as a trial');
    Stripe.Delete('/v1/subscriptions/' + Sub9);

    { --- a card that fails -------------------------------------------- }
    Cust8 := EnsureStripeCustomer('8', 'askr-testmode-8@example.com');
    P := Default(TStripeParams);
    P.Add('customer', Cust8);
    Reply := Post('/v1/payment_methods/pm_card_chargeCustomerFail/attach', P);
    P := Default(TStripeParams);
    P.Add('invoice_settings[default_payment_method]', Field(Reply, 'id'));
    Post('/v1/customers/' + Cust8, P);
    P := Default(TStripeParams);
    P.Add('customer', Cust8);
    P.Add('items[0][price]', Price);
    Reply := Post('/v1/subscriptions', P);
    Sub8 := Field(Reply, 'id');
    Invoice := Field(Reply, 'latest_invoice');
    Check(Field(Reply, 'status') = 'incomplete', 'a declined first payment: incomplete',
      Field(Reply, 'status'));
    GType := 'invoice.payment_failed';
    Check(WaitFor(@CondEvent), 'invoice.payment_failed arrived and was recorded');
    Check(not Subscribed('8'), 'incomplete is not subscribed');
    Check(Field(Stripe.Get('/v1/invoices/' + Invoice),
      'parent.subscription_details.subscription') = Sub8,
      'the invoice names its subscription where the plugin reads it');
    Stripe.Delete('/v1/subscriptions/' + Sub8);

    WriteLn('  ', Rows('SELECT count(*) FROM stripe_events'),
      ' events recorded, each once: ',
      Rows('SELECT count(DISTINCT stripe_id) FROM stripe_events'), ' distinct');
  except
    on E: Exception do
      Bad('the run stopped', E.ClassName + ': ' + E.Message);
  end;

  { --- tidy the test account ------------------------------------------ }
  try
    if Cust7 <> '' then Stripe.Delete('/v1/customers/' + Cust7);
    if Cust8 <> '' then Stripe.Delete('/v1/customers/' + Cust8);
    if Product <> '' then
    begin
      P := Default(TStripeParams);
      P.AddBool('active', False);
      Post('/v1/products/' + Product, P);
    end;
    WriteLn('  the customers are deleted and the product archived');
  except
    on E: Exception do
      WriteLn('  note  tidying up: ', E.Message);
  end;

  if Failures = 0 then
    WriteLn('test mode: ok')
  else
    WriteLn('test mode: ', Failures, ' failed');
  Halt(Ord(Failures > 0));
end.
