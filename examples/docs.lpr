{ The code in docs/, compiled.

  Every example on the plugin's pages is here, as close to how the page
  writes it as a program allows, and ./check builds this file. A page that
  names a function that does not exist, or calls one with the wrong
  arguments, then stops the check -- the framework's own docs had four
  such names in their first draft, found only by reading the source.

  It is built, not run. What the functions do is the suite's business.

  The app's own helpers the examples lean on -- AppUrl, UserEmail,
  SendWelcomeMail and the rest -- are stubs at the top. }
program DocsExamples;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils,
  Askr.Core.Clock, Askr.Auth, Askr.Http.Request, Askr.Http.Response,
  Askr.Http.Router, Askr.Events, Askr.Queue, Askr.Mail, Askr.Testing,
  Askr.Urd.Model, Askr.Urd.Sqlite, Askr.Norn.Migration,
  Askr.Plugin.Stripe, Askr.Plugin.Stripe.Client,
  Askr.Plugin.Stripe.Billing, Askr.Plugin.Stripe.Signature;

{ ---- the app's own, which the examples assume ------------------------ }

const
  ProMonthly = 'price_1Q...';

function AppUrl: string; begin Result := 'https://shop.example'; end;
function UserEmail: string; begin Result := 'ada@example.com'; end;
function RenderReports: string; begin Result := '<h1>Reports</h1>'; end;
function EmailOf(const UserId: string): string; begin Result := UserId; end;
procedure SendWelcomeMail(const UserId: string); begin end;
procedure ShipBook(const UserId, SessionId: string); begin end;
procedure GrantCredits(const UserId: string; N: Integer; const Key: string); begin end;
procedure MarkRefunded(const EventId, Payload: string); begin end;
procedure RecordFailure(const OrderId, Why: string); begin end;

{ ---- billing.md ------------------------------------------------------ }

function Subscribe(Req: TRequest): TResponse;
var
  C: TCheckout;
begin
  C := SubscriptionCheckout(ProMonthly,
    AppUrl + '/billing/thanks', AppUrl + '/pricing');
  C.TrialDays := 14;
  Result := Redirect(CheckoutUrl(Askr.Auth.Id, UserEmail, C), 303);
end;

function Reports(Req: TRequest): TResponse;
begin
  Result := RequireSubscribed(ProMonthly);
  if Result <> nil then
    Exit;
  Result := RespondHtml(RenderReports);
end;

procedure Welcome(E: TEvent);
begin
  SendWelcomeMail(TStripeSubscriptionCreated(E).UserId);
end;

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

procedure Routes(R: TRouter);
begin
  R.Post('/subscribe', @Subscribe);
  R.Get('/reports', @Reports);
  Listen(TStripeSubscriptionCreated, @Welcome);
  Listen(TStripePaymentSucceeded, @Fulfil);
end;

{ ---- customers.md ---------------------------------------------------- }

procedure Customers(const UserId, Email, Name, NewEmail: string);
var
  Customer: string;
  P: TStripeParams;
begin
  Customer := EnsureStripeCustomer(Askr.Auth.Id, Email, Name);
  if StripeCustomerId(UserId) = '' then
    Exit;

  P := Default(TStripeParams);
  P.Add('email', NewEmail);
  P.Add('address[country]', 'NO');
  Stripe.Post('/v1/customers/' + StripeCustomerId(UserId), P);

  Stripe.Delete('/v1/customers/' + StripeCustomerId(UserId));
end;

function Billing(Req: TRequest): TResponse;
begin
  if StripeCustomerId(Askr.Auth.Id) = '' then
    Exit(Redirect('/pricing', 303));
  Result := Redirect(BillingPortalUrl(Askr.Auth.Id,
    AppUrl + '/account'), 303);
end;

{ ---- subscriptions.md ------------------------------------------------ }

function Subscribe2(Req: TRequest): TResponse;
var
  C: TCheckout;
begin
  C := SubscriptionCheckout('price_pro_monthly',
    AppUrl + '/billing/thanks',    { after paying }
    AppUrl + '/pricing');          { the back link on Checkout }
  Result := Redirect(CheckoutUrl(Askr.Auth.Id, UserEmail, C), 303);
end;

procedure Checkouts(const OkUrl, BackUrl: string; Seats: Integer);
var
  C: TCheckout;
begin
  C := SubscriptionCheckout('price_team_base', OkUrl, BackUrl);
  C.Add('price_team_seat', Seats);
  C.TrialDays := 14;
  C.Extra.Add('payment_method_collection', 'if_required');
  C.Extra.Add('billing_address_collection', 'required');
  C.Extra.Add('subscription_data[description]', 'Pro plan');
  C.Extra.Add('locale', 'nb');
  C.AllowPromotionCodes := True;
  C.IdempotencyKey := 'checkout-1';
  CheckoutUrl('7', '', C);
end;

procedure Checking(const Id: string);
var
  S: TStripeSubscription;
  Paid: Boolean;
begin
  if FindSubscription(Askr.Auth.Id, S) then
    WriteLn(S.StripeId, S.Status, S.Price, Length(S.Prices),
      Length(S.ItemIds), S.Quantity, S.TrialEnd, S.CurrentPeriodEnd,
      S.CancelAtPeriodEnd, S.CancelAt, S.EndedAt, S.Valid);
  Paid := Subscribed(Id) or (FindSubscription(Id, S) and (S.Status = 'past_due'));
  WriteLn(Paid, Subscribed(Id, 'price_pro'), OnTrial(Id), OnGracePeriod(Id));
end;

function Reports2(Req: TRequest): TResponse;
begin
  Result := RequireSubscribed('price_pro_monthly', '/pricing');
  if Result <> nil then
    Exit;
  Result := RespondHtml(RenderReports);
end;

procedure Cancelling(const UserId: string);
begin
  CancelSubscription(UserId);
  ResumeSubscription(UserId);
  CancelSubscriptionNow(UserId);
end;

procedure ChangePlan(const UserId: string);
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

{ ---- payments.md ----------------------------------------------------- }

function BuyCredits(Req: TRequest): TResponse;
begin
  Result := Redirect(CheckoutUrl(Askr.Auth.Id, UserEmail,
    PaymentCheckout('price_credits_100', 1,
      AppUrl + '/credits/thanks', AppUrl + '/credits')), 303);
end;

procedure MoreLines(const OkUrl, BackUrl: string);
var
  C: TCheckout;
begin
  C := PaymentCheckout('price_book', 1, OkUrl, BackUrl);
  C.Add('price_gift_wrap', 1);
  C.Extra.Add('invoice_creation[enabled]', 'true');
end;

procedure FulfilCredits(E: TEvent);
var
  P: TStripePaymentSucceeded;
  Amount: Currency;
begin
  P := TStripePaymentSucceeded(E);
  WriteLn(P.UserId, P.SessionId, P.PaymentIntent, P.AmountTotal, P.Currency);
  GrantCredits(P.UserId, 100, P.SessionId);
  Amount := P.AmountTotal;
  Amount := Amount / 100;
  WriteLn(Amount);
end;

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

procedure Queued;
begin
  Listen(TStripePaymentSucceeded, @FulfilCredits);
  ListenQueued(Queue, TStripePaymentSucceeded, 'shop.fulfil', @FulfilCredits);
  ListenQueued(Queue, TStripePaymentFailed, 'billing.dunning', @Dunning);
end;

procedure Refund(const PaymentIntent: string);
var
  P: TStripeParams;
begin
  P := Default(TStripeParams);
  P.Add('payment_intent', PaymentIntent);
  Stripe.Post('/v1/refunds', P);
end;

{ ---- webhooks.md ----------------------------------------------------- }

procedure Refunded(E: TEvent);
var
  R: TStripeEventReceived;
begin
  R := TStripeEventReceived(E);
  if R.EventType <> 'charge.refunded' then
    Exit;
  MarkRefunded(R.EventId, R.Payload);
end;

{ ---- api.md ---------------------------------------------------------- }

procedure WebhookListeners;
begin
  Listen(TStripeEventReceived, @Refunded);
end;

procedure Api(const UserId, OrderId: string);
var
  P: TStripeParams;
  Json: string;
begin
  Json := Stripe.Get('/v1/invoices?limit=10&customer=' +
    StripeCustomerId(UserId));

  P := Default(TStripeParams);
  P.Add('amount', 5000);
  P.Add('currency', 'nok');
  P.Add('customer', StripeCustomerId(UserId));
  P.Add('description', 'Setup fee');
  Json := Stripe.Post('/v1/invoiceitems', P);
  WriteLn(StripeField(Json, 'id'));

  P := Default(TStripeParams);
  P.Add('line_items[0][price]', 'price_1');
  P.Add('line_items[0][quantity]', 2);
  P.AddBool('allow_promotion_codes', True);
  P.Add('metadata[order_id]', '1042');

  try
    Stripe.Post('/v1/invoiceitems', P, 'setup-fee-' + OrderId);
  except
    on E: EStripeError do
      if E.Retryable then
        raise
      else
        RecordFailure(OrderId, E.Message);
  end;
  WriteLn(StripeApiVersion);
end;

procedure ErrorFields(E: EStripeError);
begin
  WriteLn(E.Status, E.Type_, E.Code, E.DeclineCode, E.Param, E.RequestId,
    E.Retryable, E.Message);
end;

{ ---- testing.md ------------------------------------------------------ }

var
  Fake: TFakeStripeHttp;

procedure Fresh;
var
  M: TMigrator;
  C: TStripeClient;
begin
  UseTestDatabase;
  M := TMigrator.Create(CurrentDb);
  try
    M.Up;
  finally
    M.Free;
  end;

  Fake.Free;
  Fake := TFakeStripeHttp.Create;
  C := TStripeClient.Create('sk_test_suite');
  C.UseHttp(Fake, False);
  SetStripe(C);
  SetStripeWebhookSecret('whsec_suite');
end;

procedure TestCheckout;
var
  Url: string;
begin
  Fresh;
  Fake.Queue('{"id":"cus_1"}');
  Fake.Queue('{"id":"cs_1","url":"https://checkout.stripe.com/c/pay/cs_1"}');
  Url := CheckoutUrl('7', 'ada@example.com',
    SubscriptionCheckout('price_pro', 'https://x/ok', 'https://x/no'));
  AssertEqual(Url, 'https://checkout.stripe.com/c/pay/cs_1', 'the page');
  AssertContains(Fake.Last.Form, 'mode=subscription', 'a subscription');
end;

procedure TestWelcome;
var
  R: TRouter;
  C: TTestClient;
  Body: string;
begin
  Fresh;
  FakeEvents([]);
  Fake.Queue('{"id":"cus_A"}');
  EnsureStripeCustomer('7', 'ada@example.com');
  Body := '{"id":"evt_1","object":"event","created":' + IntToStr(UnixNow) +
    ',"type":"customer.subscription.created","data":{"object":' +
    '{"id":"sub_1","object":"subscription","customer":"cus_A",' +
    '"status":"active","items":{"data":[{"id":"si_1",' +
    '"price":{"id":"price_pro"},"quantity":1}]}}}}';

  R := TRouter.Create;
  R.Post('/stripe/webhook', StripeWebhook);
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
  WriteLn(DispatchedEventJson(TStripeSubscriptionCreated));
end;

procedure MockClient;
begin
  SetStripe(TStripeClient.Create('sk_test_mock', 'http://localhost:12111'));
end;

begin
  { Built, not run: this references everything above so none of it is
    left out of the check by the linker's view of what is used. }
  if ParamCount > 1000 then
  begin
    Routes(nil); Customers('', '', '', ''); Billing(nil);
    Checkouts('', '', 1); Checking(''); Reports2(nil); Cancelling('');
    ChangePlan(''); BuyCredits(nil); MoreLines('', ''); Queued;
    Refund(''); Refunded(nil); Api('', ''); ErrorFields(nil);
    TestCheckout; TestWelcome; MockClient; BuyBook(nil);
    Subscribe2(nil); WebhookListeners;
  end;
end.
