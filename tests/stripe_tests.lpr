{ The plugin's suite.

  Four things hold it, and each covers what the others cannot:

  * tests/vectors/signatures.txt, stripe-python's own verdict on thirty
    Stripe-Signature headers;
  * a fake HTTP layer, for what the plugin sends and does with a reply;
  * a raw socket, for the headers on the wire -- the one layer the fake
    skips;
  * stripe-mock, Stripe's server built from its OpenAPI spec, which refuses
    a top-level parameter it does not know. STRIPE_MOCK_URL points at it;
    ./check starts one.

  None of this is Stripe itself. What a real test-mode account says is
  another run, and the README says whether it has been made. }
program StripeTests;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils, Classes, StrUtils, Sockets, BaseUnix, Askr.Core.Arena,
  Askr.Core.Text, Askr.Core.Clock, Askr.Core.Crypto, Askr.Core.Log,
  Askr.Http.Router, Askr.Http.Response, Askr.Urd.Driver, Askr.Urd.Model,
  Askr.Urd.Sqlite, Askr.Norn.Migration, Askr.Events, Askr.Testing,
  Askr.Plugin.Stripe, Askr.Plugin.Stripe.Client,
  Askr.Plugin.Stripe.Signature, Askr.Plugin.Stripe.Billing,
  Askr.Plugin.Stripe.CreateTables;

const
  WebhookSecret = 'whsec_suite_secret';
  Secret = 'sk_test_suite_secret';

var
  GFake: TFakeStripeHttp = nil;
  GRouter: TRouter = nil;

{ --------------------------------------------------------------- setup -- }

procedure Quiet(const Line: string);
begin
end;

{ A fresh database with the plugin's tables, a fake Stripe, and the webhook
  secret set. Every test that touches the database starts here. }
procedure Fresh;
var
  M: TMigrator;
  C: TStripeClient;
begin
  StopFakingEvents;
  ClearListeners;
  UseTestDatabase;
  M := TMigrator.Create(CurrentDb);
  M.OnLog := @Quiet;
  try
    M.Up;
  finally
    M.Free;
  end;
  GFake.Free;
  GFake := TFakeStripeHttp.Create;
  C := TStripeClient.Create(Secret);
  C.UseHttp(GFake, False);
  SetStripe(C);
  SetStripeWebhookSecret(WebhookSecret);
  if GRouter = nil then
  begin
    GRouter := TRouter.Create;
    GRouter.Post('/stripe/webhook', StripeWebhook);
  end;
end;

function Count(const Sql: string): Int64;
var
  A: TArena;
  R: TDbResult;
begin
  A := TArena.Create(4096);
  try
    R := CurrentDb.Exec(A, Sql);
    Result := R.AsInt64(0, 0);
  finally
    A.Free;
  end;
end;

function Scalar(const Sql: string): string;
var
  A: TArena;
  R: TDbResult;
begin
  Result := '';
  A := TArena.Create(4096);
  try
    R := CurrentDb.Exec(A, Sql);
    if (R <> nil) and not R.IsEmpty then
      Result := R.Value(0, 0).ToString;
  finally
    A.Free;
  end;
end;

procedure Customer(const UserId, StripeId: string);
var
  A: TArena;
begin
  A := TArena.Create(4096);
  try
    CurrentDb.Exec(A, 'INSERT INTO stripe_customers (user_id, stripe_id, ' +
      'created_at) VALUES (''' + UserId + ''', ''' + StripeId + ''', 0)');
  finally
    A.Free;
  end;
end;

{ A subscription object as Stripe sends it on 2026-08-26.dahlia: the
  period end on the items. }
function Sub(const Id, Status: string; const Prices: array of string;
  TrialEnd, PeriodEnd: Int64; CancelAtPeriodEnd: Boolean;
  const Cust: string = 'cus_A'; const Metadata: string = '{}'): string;
var
  I: Integer;
  Items: string;
begin
  Items := '';
  for I := 0 to High(Prices) do
  begin
    if I > 0 then
      Items := Items + ',';
    Items := Items + '{"id":"si_' + Id + '_' + IntToStr(I) +
      '","object":"subscription_item","price":{"id":"' + Prices[I] +
      '","object":"price"},"quantity":' + IntToStr(I + 1) +
      ',"current_period_end":' + IntToStr(PeriodEnd) + '}';
  end;
  Result := '{"id":"' + Id + '","object":"subscription","customer":"' +
    Cust + '","status":"' + Status + '","items":{"object":"list","data":[' +
    Items + ']},"trial_end":' + IfThen(TrialEnd = 0, 'null', IntToStr(TrialEnd)) +
    ',"cancel_at":null,"ended_at":null,"cancel_at_period_end":' +
    BoolToStr(CancelAtPeriodEnd, 'true', 'false') + ',"metadata":' +
    Metadata + '}';
end;

function Event(const Id, EventType: string; Created: Int64;
  const Obj: string): string;
begin
  Result := '{"id":"' + Id + '","object":"event","api_version":"' +
    StripeApiVersion + '","created":' + IntToStr(Created) +
    ',"type":"' + EventType + '","data":{"object":' + Obj + '}}';
end;

function Deliver(const Body: string; const Sig: string = ''): TResponse;
var
  C: TTestClient;
  H: string;
begin
  H := Sig;
  if H = '' then
    H := StripeSignatureHeader(Body, WebhookSecret, UnixNow);
  C := TTestClient.Create(GRouter);
  try
    Result := C.WithHeader('Stripe-Signature', H)
      .Post('/stripe/webhook', Body);
  finally
    C.Free;
  end;
end;

{ ---------------------------------------------------------- signature -- }

procedure TestSignatureVectors;
var
  F, Cols: TStringList;
  I, Checked: Integer;
  Payload: TBytes;
  P, Got: string;
begin
  F := TStringList.Create;
  Cols := TStringList.Create;
  try
    F.LoadFromFile('tests/vectors/signatures.txt');
    Cols.Delimiter := #9;
    Cols.StrictDelimiter := True;
    Checked := 0;
    for I := 0 to F.Count - 1 do
    begin
      if (F[I] = '') or (F[I][1] = '#') then
        Continue;
      Cols.DelimitedText := F[I];
      AssertEqual(Cols.Count, 7, 'a vector has seven columns: ' + Cols[0]);
      Payload := HexDecode(Cols[1]);
      SetLength(P, Length(Payload));
      if Length(Payload) > 0 then
        Move(Payload[0], P[1], Length(Payload));
      Got := SignatureCheckName(VerifyStripeSignature(P, Cols[2], Cols[3],
        StrToInt64(Cols[5]), StrToInt64(Cols[4])));
      AssertEqual(Got, Cols[6], Cols[0]);
      Inc(Checked);
    end;
    { A file that failed to load, or lost its lines, would pass every
      assert above by having none. }
    AssertEqual(Checked, 30, 'all thirty vectors were read');
  finally
    Cols.Free;
    F.Free;
  end;
end;

procedure TestSignatureHeaderRoundTrip;
var
  H: string;
begin
  H := StripeSignatureHeader('{"a":1}', WebhookSecret, 1700000000);
  AssertTrue(Copy(H, 1, 13) = 't=1700000000,', 'the timestamp first');
  AssertTrue(VerifyStripeSignature('{"a":1}', H, WebhookSecret, 300,
    1700000001) = scOk, 'a header this makes is one the check accepts');
end;

{ -------------------------------------------------------------- client -- }

procedure TestParamsEncode;
var
  P: TStripeParams;
begin
  P := Default(TStripeParams);
  P.Add('mode', 'subscription');
  P.Add('line_items[0][price]', 'price_1');
  P.Add('line_items[0][quantity]', 2);
  P.Add('success_url', 'https://shop.example/done?a=1&b=2');
  P.Add('name', 'Blåbær + 🫐');
  P.AddBool('allow_promotion_codes', True);
  AssertEqual(P.Encode,
    'mode=subscription' +
    '&line_items%5B0%5D%5Bprice%5D=price_1' +
    '&line_items%5B0%5D%5Bquantity%5D=2' +
    '&success_url=https%3A%2F%2Fshop.example%2Fdone%3Fa%3D1%26b%3D2' +
    '&name=Bl%C3%A5b%C3%A6r%20%2B%20%F0%9F%AB%90' +
    '&allow_promotion_codes=true',
    'in order, both sides encoded, a plus that stays a plus');
end;

procedure TestClientSends;
var
  C: TStripeClient;
  F: TFakeStripeHttp;
  P: TStripeParams;
  First: string;
begin
  F := TFakeStripeHttp.Create;
  C := TStripeClient.Create(Secret, 'http://mock.test/');
  try
    C.UseHttp(F, False);
    F.Queue('{"id":"cus_1"}');
    F.Queue('{"id":"cus_2"}');
    F.Queue('{"id":"cus_3"}');
    F.Queue('{"id":"sub_1"}');
    P := Default(TStripeParams);
    P.Add('email', 'a@example.com');
    C.Post('/v1/customers', P, 'job-77');
    AssertEqual(F.Last.Method, 'POST', 'the method');
    AssertEqual(F.Last.Url, 'http://mock.test/v1/customers',
      'the base url without its trailing slash, and the path');
    AssertEqual(F.Last.Secret, Secret, 'the secret goes to the HTTP layer');
    AssertEqual(F.Last.IdempotencyKey, 'job-77', 'the caller''s key');
    AssertEqual(F.Last.Form, 'email=a%40example.com', 'the form');

    C.Post('/v1/customers', P);
    First := F.Last.IdempotencyKey;
    AssertTrue(Copy(First, 1, 5) = 'askr-', 'a key of its own without one');
    C.Post('/v1/customers', P);
    AssertTrue(F.Last.IdempotencyKey <> First,
      'and a new one each time: a random key covers a retry in this ' +
      'process, not a second request');

    C.Get('/v1/subscriptions/sub_1');
    AssertEqual(F.Last.Method, 'GET', 'GET');
    AssertEqual(F.Last.IdempotencyKey, '', 'no key on a GET');
    AssertEqual(F.Last.Form, '', 'no body on a GET');
    AssertEqual(C.LastRequestId, 'req_fake_4', 'the Request-Id is kept');
    AssertNotContains(C.Describe, Secret, 'Describe has no secret');
  finally
    C.Free;
    F.Free;
  end;
end;

function Raised(C: TStripeClient; out E: EStripeError): Boolean;
var
  P: TStripeParams;
begin
  E := nil;
  P := Default(TStripeParams);
  try
    C.Post('/v1/customers', P);
    Result := False;
  except
    on X: EStripeError do
    begin
      E := EStripeError.Create(X.Status, X.Type_, X.Code, X.Param,
        X.DeclineCode, X.RequestId, X.Message, X.Retryable);
      Result := True;
    end;
  end;
end;

procedure TestClientErrors;
var
  C: TStripeClient;
  F: TFakeStripeHttp;
  E: EStripeError;
begin
  F := TFakeStripeHttp.Create;
  C := TStripeClient.Create(Secret);
  try
    C.UseHttp(F, False);
    F.Queue('{"error":{"type":"card_error","code":"card_declined",' +
      '"decline_code":"insufficient_funds","param":"source",' +
      '"message":"Your card was declined."}}', 402);
    AssertTrue(Raised(C, E), 'a 402 raises');
    AssertEqual(E.Status, 402, 'the status');
    AssertEqual(E.Type_, 'card_error', 'Stripe''s type');
    AssertEqual(E.Code, 'card_declined', 'the code');
    AssertEqual(E.DeclineCode, 'insufficient_funds', 'the decline code');
    AssertEqual(E.Param, 'source', 'the param');
    AssertContains(E.Message, 'Your card was declined.', 'Stripe''s message');
    AssertFalse(E.Retryable, 'a declined card is not declined less next time');
    E.Free;

    F.Queue('{"error":{"type":"invalid_request_error","message":"Too many"}}', 429);
    AssertTrue(Raised(C, E) and E.Retryable, 'a 429 is worth another try');
    E.Free;
    F.Queue('{"error":{"type":"api_error","message":"x"}}', 500);
    AssertTrue(Raised(C, E) and E.Retryable, 'so is a 500');
    E.Free;
    F.Queue('{"error":{"type":"idempotency_error","message":"x"}}', 409);
    AssertTrue(Raised(C, E) and E.Retryable,
      'and a 409: a concurrent request with the same key');
    E.Free;
    F.Queue('{"error":{"type":"invalid_request_error","message":"x"}}', 400, 'true');
    AssertTrue(Raised(C, E) and E.Retryable,
      'Stripe-Should-Retry: true wins over the status');
    E.Free;
    F.Queue('{"error":{"type":"api_error","message":"x"}}', 503, 'false');
    AssertTrue(Raised(C, E) and not E.Retryable,
      'and Stripe-Should-Retry: false wins the other way');
    E.Free;
    F.Queue('<html>Bad gateway</html>', 502);
    AssertTrue(Raised(C, E), 'a reply that is not JSON raises');
    AssertContains(E.Message, '502', 'with its status');
    AssertNotContains(E.Message, '<html>', 'and not somebody else''s page');
    E.Free;
  finally
    C.Free;
    F.Free;
  end;
end;

procedure TestNoSecret;
var
  C: TStripeClient;
  F: TFakeStripeHttp;
  E: EStripeError;
begin
  F := TFakeStripeHttp.Create;
  C := TStripeClient.Create('');
  try
    C.UseHttp(F, False);
    AssertTrue(Raised(C, E), 'no secret raises');
    AssertEqual(E.Type_, 'config', 'as configuration');
    AssertContains(E.Message, 'STRIPE_SECRET', 'naming the variable');
    AssertEqual(F.SentCount, 0, 'and nothing was sent');
    E.Free;
  finally
    C.Free;
    F.Free;
  end;
end;

{ A server that reads one request and answers it: the bytes that were
  actually sent. The fake skips exactly the layer that puts the headers on
  the wire. }
type
  TCaptureServer = class(TThread)
  private
    FListen: TSocket;
    FPort: Word;
    FRequest: string;
  protected
    procedure Execute; override;
  public
    constructor Create;
    property Port: Word read FPort;
    property Request: string read FRequest;
  end;

constructor TCaptureServer.Create;
var
  Addr: TInetSockAddr;
  Len: TSockLen;
  Yes: Integer;
begin
  FListen := fpSocket(AF_INET, SOCK_STREAM, 0);
  Yes := 1;
  fpSetSockOpt(FListen, SOL_SOCKET, SO_REUSEADDR, @Yes, SizeOf(Yes));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_addr.s_addr := HToNL($7F000001);
  Addr.sin_port := 0;
  fpBind(FListen, @Addr, SizeOf(Addr));
  fpListen(FListen, 4);
  Len := SizeOf(Addr);
  fpGetSockName(FListen, @Addr, @Len);
  FPort := NToHS(Addr.sin_port);
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TCaptureServer.Execute;
var
  S: TSocket;
  Reply, Chunk: string;
  N: ssize_t;
  Buf: array[0..8191] of Byte;
  HeadEnd, Want, P: Integer;
begin
  S := fpAccept(FListen, nil, nil);
  if S >= 0 then
  begin
    { Until the head and Content-Length bytes of body are in: one recv is
      not promised to hold a whole request. }
    Want := -1;
    repeat
      N := fpRecv(S, @Buf[0], SizeOf(Buf), 0);
      if N <= 0 then
        Break;
      SetLength(Chunk, N);
      Move(Buf[0], Chunk[1], N);
      FRequest := FRequest + Chunk;
      HeadEnd := Pos(#13#10#13#10, FRequest);
      if (HeadEnd > 0) and (Want < 0) then
      begin
        Want := 0;
        P := Pos('Content-Length: ', FRequest);
        if (P > 0) and (P < HeadEnd) then
          Want := StrToIntDef(Trim(Copy(FRequest, P + 16,
            PosEx(#13#10, FRequest, P) - P - 16)), 0);
      end;
    until (Want >= 0) and (Length(FRequest) >= HeadEnd + 3 + Want);
    Reply := '{"id":"cus_wire"}';
    Reply := 'HTTP/1.1 200 OK'#13#10 +
      'Content-Type: application/json'#13#10 +
      'Request-Id: req_wire_1'#13#10 +
      'Content-Length: ' + IntToStr(Length(Reply)) + #13#10 +
      'Connection: close'#13#10#13#10 + Reply;
    fpSend(S, PChar(Reply), Length(Reply), 0);
    CloseSocket(S);
  end;
  CloseSocket(FListen);
end;

procedure TestOnTheWire;
var
  Srv: TCaptureServer;
  C: TStripeClient;
  P: TStripeParams;
  R: string;
begin
  Srv := TCaptureServer.Create;
  try
    C := TStripeClient.Create(Secret, 'http://127.0.0.1:' + IntToStr(Srv.Port));
    try
      P := Default(TStripeParams);
      P.Add('metadata[askr_user_id]', '7');
      AssertEqual(StripeField(C.Post('/v1/customers', P, 'askr-customer-7'),
        'id'), 'cus_wire', 'the reply is read');
      AssertEqual(C.LastRequestId, 'req_wire_1', 'the Request-Id header is read');
    finally
      C.Free;
    end;
    Srv.WaitFor;
    R := Srv.Request;
    AssertContains(R, 'POST /v1/customers HTTP/1.1', 'the method and path');
    AssertContains(R, 'Authorization: Bearer ' + Secret, 'the secret as a Bearer');
    AssertContains(R, 'Stripe-Version: ' + StripeApiVersion, 'the pinned version');
    AssertContains(R, 'Idempotency-Key: askr-customer-7', 'the idempotency key');
    AssertContains(R, 'Content-Type: application/x-www-form-urlencoded',
      'a form, not JSON');
    AssertContains(R, #13#10#13#10'metadata%5Baskr_user_id%5D=7', 'the body');
  finally
    Srv.Free;
  end;
end;

{ ------------------------------------------------------------- billing -- }

procedure TestCustomerOnce;
var
  Id: string;
begin
  Fresh;
  GFake.Queue('{"id":"cus_new","object":"customer"}');
  Id := EnsureStripeCustomer('7', 'ada@example.com', 'Ada');
  AssertEqual(Id, 'cus_new', 'the id Stripe gave');
  AssertEqual(GFake.Last.Url, DefaultStripeBaseUrl + '/v1/customers', 'the path');
  AssertContains(GFake.Last.Form, 'metadata%5Baskr_user_id%5D=7',
    'the user id goes along, the way back from Stripe''s side');
  AssertEqual(GFake.Last.IdempotencyKey, 'askr-customer-7',
    'keyed by the user, so two requests racing make one customer');
  AssertEqual(Scalar('SELECT stripe_id FROM stripe_customers WHERE user_id = ''7'''),
    'cus_new', 'and kept');

  AssertEqual(EnsureStripeCustomer('7', 'ada@example.com'), 'cus_new',
    'the second time it is read');
  AssertEqual(GFake.SentCount, 1, 'without asking Stripe again');
  AssertEqual(StripeCustomerId('8'), '', 'another user has none');
end;

procedure TestCheckout;
var
  C: TCheckout;
  Url, F: string;
begin
  Fresh;
  Customer('7', 'cus_A');
  GFake.Queue('{"id":"cs_1","url":"https://checkout.stripe.com/c/pay/cs_1"}');
  C := SubscriptionCheckout('price_pro', 'https://shop.example/ok',
    'https://shop.example/no');
  C.TrialDays := 14;
  C.IdempotencyKey := 'checkout-7-1';
  Url := CheckoutUrl('7', 'ada@example.com', C);
  AssertEqual(Url, 'https://checkout.stripe.com/c/pay/cs_1', 'the url to send them to');
  AssertEqual(GFake.SentCount, 1, 'the customer was there already');
  F := GFake.Last.Form;
  AssertContains(F, 'mode=subscription', 'the mode');
  AssertContains(F, 'customer=cus_A', 'the customer');
  AssertContains(F, 'client_reference_id=7', 'the user');
  AssertContains(F, 'line_items%5B0%5D%5Bprice%5D=price_pro', 'the price');
  AssertContains(F, 'line_items%5B0%5D%5Bquantity%5D=1', 'the quantity');
  AssertContains(F, 'subscription_data%5Btrial_period_days%5D=14', 'the trial');
  AssertContains(F, 'subscription_data%5Bmetadata%5D%5Baskr_user_id%5D=7',
    'the user on the subscription too');
  AssertEqual(GFake.Last.IdempotencyKey, 'checkout-7-1', 'the caller''s key');

  C := PaymentCheckout('price_book', 3, 'https://shop.example/ok', '');
  C.TrialDays := 7;
  try
    CheckoutUrl('7', '', C);
    Fail('a payment with a trial was sent');
  except
    on E: EStripeError do
      AssertContains(E.Message, 'trial', 'a trial is refused on a payment');
  end;
  AssertEqual(GFake.SentCount, 1, 'before anything is sent');
end;

procedure TestPortal;
begin
  Fresh;
  try
    BillingPortalUrl('7', 'https://shop.example/account');
    Fail('a portal without a customer');
  except
    on E: EStripeError do
      AssertContains(E.Message, 'no Stripe customer', 'says why');
  end;
  Customer('7', 'cus_A');
  GFake.Queue('{"url":"https://billing.stripe.com/p/session/x"}');
  AssertEqual(BillingPortalUrl('7', 'https://shop.example/account'),
    'https://billing.stripe.com/p/session/x', 'the portal');
  AssertEqual(GFake.Last.Form,
    'customer=cus_A&return_url=https%3A%2F%2Fshop.example%2Faccount', 'the form');
end;

{ ------------------------------------------------------------ webhooks -- }

procedure TestWebhookCreates;
var
  R: TResponse;
  Body: string;
  S: TStripeSubscription;
begin
  Fresh;
  Customer('7', 'cus_A');
  FakeEvents([]);
  Body := Event('evt_1', 'customer.subscription.created', UnixNow,
    Sub('sub_1', 'active', ['price_pro', 'price_seats'], 0, UnixNow + 86400, False));
  R := Deliver(Body);
  AssertStatus(R, 200, 'a signed event is taken');
  AssertTrue(Subscribed('7'), 'the user is subscribed');
  AssertTrue(Subscribed('7', 'price_pro'), 'to the first price');
  AssertTrue(Subscribed('7', 'price_seats'), 'and to the second item''s');
  AssertFalse(Subscribed('7', 'price_other'), 'not to another');
  AssertFalse(Subscribed('8'), 'nor is anybody else');
  AssertTrue(FindSubscription('7', S), 'the subscription is found');
  AssertEqual(S.Price, 'price_pro', 'the first item''s price');
  AssertEqual(Length(S.Prices), 2, 'both prices');
  AssertTrue(S.CurrentPeriodEnd > UnixNow, 'the period end, read off the item');
  AssertEqual(EventsDispatched(TStripeSubscriptionCreated), 1, 'Created, once');
  AssertEqual(EventsDispatched(TStripeEventReceived), 1, 'and the event itself');
  AssertContains(DispatchedEventJson(TStripeSubscriptionCreated), '"UserId":"7"',
    'carrying the user');

  R := Deliver(Body);
  AssertStatus(R, 200, 'the same event again is answered');
  AssertEqual(EventsDispatched(TStripeSubscriptionCreated), 1,
    'and nothing happens twice');
  AssertEqual(EventsDispatched(TStripeEventReceived), 1, 'not even the event');
  AssertEqual(Count('SELECT count(*) FROM stripe_events'), 1, 'one row');
end;

procedure TestWebhookRefuses;
var
  Body: string;
begin
  Fresh;
  Customer('7', 'cus_A');
  FakeEvents([]);
  Body := Event('evt_1', 'customer.subscription.created', UnixNow,
    Sub('sub_1', 'active', ['price_pro'], 0, 0, False));
  AssertStatus(Deliver(Body, 't=' + IntToStr(UnixNow) + ',v1=' +
    StringOfChar('0', 64)), 400, 'a bad signature is refused');
  AssertStatus(Deliver(Body, StripeSignatureHeader(Body, WebhookSecret,
    UnixNow - 3600)), 400, 'so is an old one');
  AssertStatus(Deliver(Body, StripeSignatureHeader(Body, 'whsec_other',
    UnixNow)), 400, 'and one under another secret');
  AssertEqual(Count('SELECT count(*) FROM stripe_events'), 0, 'nothing recorded');
  AssertEqual(EventsDispatched(TStripeEventReceived), 0, 'nothing dispatched');
  AssertFalse(Subscribed('7'), 'nothing changed');

  AssertStatus(Deliver('{"object":"list"}'), 400,
    'a signed body that is not an event is refused');

  SetStripeWebhookSecret('');
  AssertStatus(Deliver(Body, StripeSignatureHeader(Body, '', UnixNow)), 500,
    'without a webhook secret nothing is taken, and Stripe will retry');
  AssertEqual(Count('SELECT count(*) FROM stripe_events'), 0, 'still nothing');
end;

procedure TestWebhookOrder;
var
  S: TStripeSubscription;
  T: Int64;
begin
  Fresh;
  Customer('7', 'cus_A');
  FakeEvents([]);
  T := UnixNow;
  { The update arrives first, and then the older create. }
  AssertStatus(Deliver(Event('evt_2', 'customer.subscription.updated', T + 10,
    Sub('sub_1', 'past_due', ['price_pro'], 0, 0, False))), 200, 'the update');
  AssertStatus(Deliver(Event('evt_1', 'customer.subscription.created', T,
    Sub('sub_1', 'active', ['price_pro'], 0, 0, False))), 200, 'the create');
  AssertTrue(FindSubscription('7', S), 'found');
  AssertEqual(S.Status, 'past_due', 'the older event did not overwrite the newer');
  AssertFalse(Subscribed('7'), 'past_due is not subscribed');
  AssertEqual(EventsDispatched(TStripeSubscriptionCreated), 1,
    'the listeners still heard the create');
  AssertEqual(EventsDispatched(TStripeSubscriptionUpdated), 1, 'and the update');

  AssertStatus(Deliver(Event('evt_3', 'customer.subscription.updated', T + 20,
    Sub('sub_1', 'active', ['price_team'], 0, 0, False))), 200, 'a newer one');
  AssertTrue(FindSubscription('7', S) and (S.Status = 'active'), 'applies');
  AssertFalse(S.HasPrice('price_pro'), 'the item that is gone is gone');
  AssertTrue(S.HasPrice('price_team'), 'and the new one is there');
  AssertEqual(Count('SELECT count(*) FROM stripe_subscription_items'), 1,
    'one item row');
end;

procedure TestWebhookTrialGraceCancel;
var
  T: Int64;
begin
  Fresh;
  Customer('7', 'cus_A');
  FakeEvents([]);
  T := UnixNow;
  Deliver(Event('evt_1', 'customer.subscription.created', T,
    Sub('sub_1', 'trialing', ['price_pro'], T + 86400, T + 86400, False)));
  AssertTrue(OnTrial('7'), 'on trial');
  AssertTrue(Subscribed('7'), 'and a trial is subscribed');
  AssertFalse(OnGracePeriod('7'), 'not cancelled');

  Deliver(Event('evt_2', 'customer.subscription.updated', T + 1,
    Sub('sub_1', 'active', ['price_pro'], 0, T + 3600, True)));
  AssertFalse(OnTrial('7'), 'the trial is over');
  AssertTrue(OnGracePeriod('7'), 'cancelled, and running to the period''s end');
  AssertTrue(Subscribed('7'), 'still subscribed until then');

  Deliver(Event('evt_3', 'customer.subscription.deleted', T + 2,
    Sub('sub_1', 'canceled', ['price_pro'], 0, T + 3600, True)));
  AssertFalse(Subscribed('7'), 'ended');
  AssertFalse(OnGracePeriod('7'), 'and no grace after the end');
  AssertEqual(EventsDispatched(TStripeSubscriptionCancelled), 1, 'Cancelled');
end;

{ The webhook that moves a subscription on can be late. Until it comes, the
  row's own times answer: a trial whose end has passed is not a trial, and a
  grace period whose end has passed is not a grace period. }
procedure TestLateWebhook;
var
  S: TStripeSubscription;
  T: Int64;
begin
  Fresh;
  Customer('7', 'cus_A');
  FakeEvents([]);
  T := UnixNow;
  Deliver(Event('evt_1', 'customer.subscription.created', T,
    Sub('sub_1', 'trialing', ['price_pro'], T - 60, T + 86400, False)));
  AssertFalse(OnTrial('7'), 'a trial that ended a minute ago');
  Deliver(Event('evt_2', 'customer.subscription.updated', T + 1,
    Sub('sub_1', 'active', ['price_pro'], 0, T - 60, True)));
  AssertFalse(OnGracePeriod('7'), 'a grace period that ended a minute ago');

  Deliver(Event('evt_3', 'customer.subscription.created', T,
    Sub('sub_2', 'past_due', ['price_pro'], 0, T + 3600, False, 'cus_A')));
  Deliver(Event('evt_4', 'customer.subscription.updated', T + 2,
    Sub('sub_1', 'canceled', ['price_pro'], 0, T - 60, True)));
  AssertTrue(FindSubscription('7', S), 'found');
  AssertEqual(S.StripeId, 'sub_2', 'the newest, when none is valid');
  AssertFalse(S.Valid, 'past_due is not valid');
  AssertFalse(Subscribed('7'), 'nor subscribed');
  try
    CancelSubscription('7');
    Fail('cancelled a subscription that is not valid');
  except
    on E: EStripeError do
      AssertEqual(E.Type_, 'config', 'refused before Stripe is asked');
  end;
  AssertEqual(GFake.SentCount, 0, 'nothing sent');
end;

procedure FailingListener(E: TEvent);
begin
  raise Exception.Create('the listener failed');
end;

procedure TestWebhookRollsBack;
var
  Body: string;
  PrevLevel: TLogLevel;
begin
  Fresh;
  Customer('7', 'cus_A');
  Listen(TStripeSubscriptionCreated, FailingListener);
  Body := Event('evt_1', 'customer.subscription.created', UnixNow,
    Sub('sub_1', 'active', ['price_pro'], 0, 0, False));
  PrevLevel := LogLevel;
  SetLogLevel(llNone);
  try
    AssertStatus(Deliver(Body), 500, 'a listener that fails fails the webhook');
  finally
    SetLogLevel(PrevLevel);
  end;
  AssertEqual(Count('SELECT count(*) FROM stripe_events'), 0,
    'the event is not recorded, so the retry is not a duplicate');
  AssertFalse(Subscribed('7'), 'and the subscription went with it');

  ClearListeners;
  AssertStatus(Deliver(Body), 200, 'Stripe''s retry');
  AssertTrue(Subscribed('7'), 'applies');
end;

procedure TestWebhookPayments;
var
  Paid, Unpaid: string;
begin
  Fresh;
  Customer('7', 'cus_A');
  FakeEvents([]);
  Paid := '{"id":"cs_1","object":"checkout.session","mode":"payment",' +
    '"payment_status":"paid","customer":"cus_A","client_reference_id":"7",' +
    '"payment_intent":"pi_1","amount_total":12900,"currency":"nok"}';
  Unpaid := StringReplace(StringReplace(Paid, '"paid"', '"unpaid"', []),
    'cs_1', 'cs_2', []);
  Deliver(Event('evt_1', 'checkout.session.completed', UnixNow, Paid));
  Deliver(Event('evt_2', 'checkout.session.completed', UnixNow, Unpaid));
  AssertEqual(EventsDispatched(TStripePaymentSucceeded), 1,
    'a paid session, and not the unpaid one');
  AssertContains(DispatchedEventJson(TStripePaymentSucceeded),
    '"AmountTotal":12900', 'minor units, as Stripe counts');
  Deliver(Event('evt_3', 'checkout.session.async_payment_succeeded', UnixNow,
    StringReplace(Unpaid, '"unpaid"', '"paid"', [])));
  AssertEqual(EventsDispatched(TStripePaymentSucceeded), 2,
    'a bank debit that settled later');
  Deliver(Event('evt_4', 'checkout.session.completed', UnixNow,
    '{"id":"cs_3","object":"checkout.session","mode":"subscription",' +
    '"payment_status":"paid","customer":"cus_A"}'));
  AssertEqual(EventsDispatched(TStripePaymentSucceeded), 2,
    'a subscription checkout is told by the subscription''s own events');

  Deliver(Event('evt_5', 'invoice.payment_failed', UnixNow,
    '{"id":"in_1","object":"invoice","customer":"cus_A","amount_due":9900,' +
    '"currency":"nok","parent":{"subscription_details":{"subscription":"sub_9"}}}'));
  AssertEqual(EventsDispatched(TStripePaymentFailed), 1, 'a failed renewal');
  AssertContains(DispatchedEventJson(TStripePaymentFailed),
    '"SubscriptionId":"sub_9"', 'the subscription, from where it is now');
  AssertContains(DispatchedEventJson(TStripePaymentFailed), '"UserId":"7"',
    'and the user');
end;

procedure TestWebhookUnknownCustomer;
var
  PrevLevel: TLogLevel;
begin
  Fresh;
  FakeEvents([]);
  PrevLevel := LogLevel;
  SetLogLevel(llNone);
  try
    AssertStatus(Deliver(Event('evt_1', 'customer.subscription.created', UnixNow,
      Sub('sub_1', 'active', ['price_pro'], 0, 0, False, 'cus_nobody'))), 200,
      'a subscription for a customer nobody here has is answered');
  finally
    SetLogLevel(PrevLevel);
  end;
  AssertEqual(Count('SELECT count(*) FROM stripe_subscriptions'), 0,
    'and given to nobody');
  AssertEqual(EventsDispatched(TStripeEventReceived), 1, 'but it is dispatched');

  AssertStatus(Deliver(Event('evt_2', 'customer.subscription.created', UnixNow,
    Sub('sub_2', 'active', ['price_pro'], 0, 0, False, 'cus_elsewhere',
    '{"askr_user_id":"9"}'))), 200, 'one whose metadata names a user');
  AssertTrue(Subscribed('9'), 'goes to that user');
end;

procedure TestCancelAppliesReply;
var
  S: TStripeSubscription;
begin
  Fresh;
  Customer('7', 'cus_A');
  FakeEvents([]);
  Deliver(Event('evt_1', 'customer.subscription.created', UnixNow - 60,
    Sub('sub_1', 'active', ['price_pro'], 0, UnixNow + 3600, False)));
  GFake.Queue(Sub('sub_1', 'active', ['price_pro'], 0, UnixNow + 3600, True));
  CancelSubscription('7');
  AssertEqual(GFake.Last.Url, DefaultStripeBaseUrl + '/v1/subscriptions/sub_1',
    'the subscription');
  AssertEqual(GFake.Last.Form, 'cancel_at_period_end=true', 'at the period''s end');
  AssertTrue(OnGracePeriod('7'), 'the reply is in the table at once');

  GFake.Queue(Sub('sub_1', 'canceled', ['price_pro'], 0, UnixNow + 3600, False));
  CancelSubscriptionNow('7');
  AssertEqual(GFake.Last.Method, 'DELETE', 'now is a DELETE');
  AssertTrue(FindSubscription('7', S) and (S.Status = 'canceled'), 'ended');
  try
    ResumeSubscription('7');
    Fail('resumed an ended subscription');
  except
    on E: EStripeError do
      AssertContains(E.Message, 'no active subscription', 'says why');
  end;
end;

{ ---------------------------------------------------------- stripe-mock -- }

procedure TestStripeMock;
var
  Url, Id: string;
  C: TStripeClient;
  P: TStripeParams;
  Ck: TCheckout;
  Raised_: Boolean;
begin
  Url := GetEnvironmentVariable('STRIPE_MOCK_URL');
  if Url = '' then
    Fail('STRIPE_MOCK_URL is not set. ./check starts stripe-mock and sets ' +
      'it; run the suite through it.');
  Fresh;
  C := TStripeClient.Create('sk_test_mock', Url);
  SetStripe(C);

  Id := EnsureStripeCustomer('7', 'ada@example.com', 'Ada');
  AssertTrue(Copy(Id, 1, 4) = 'cus_', 'stripe-mock made a customer');

  Ck := SubscriptionCheckout('price_pro', 'https://shop.example/ok',
    'https://shop.example/no');
  Ck.TrialDays := 14;
  Ck.AllowPromotionCodes := True;
  AssertTrue(Pos('https://', CheckoutUrl('7', '', Ck)) = 1,
    'a subscription checkout it accepts');
  Ck := PaymentCheckout('price_book', 2, 'https://shop.example/ok',
    'https://shop.example/no');
  AssertTrue(Pos('https://', CheckoutUrl('7', '', Ck)) = 1,
    'and a payment');
  AssertTrue(Pos('https://', BillingPortalUrl('7', 'https://shop.example/')) = 1,
    'the portal');

  P := Default(TStripeParams);
  P.AddBool('cancel_at_period_end', True);
  AssertEqual(StripeField(C.Post('/v1/subscriptions/sub_1', P), 'object'),
    'subscription', 'the cancel request');
  AssertEqual(StripeField(C.Delete('/v1/subscriptions/sub_1'), 'object'),
    'subscription', 'and ending one now');

  { The check that makes it worth running: a parameter Stripe does not
    have is refused. It holds for top-level names only -- stripe-mock does
    not check the keys inside line_items[0]. }
  P := Default(TStripeParams);
  P.Add('emial', 'a@example.com');
  Raised_ := False;
  try
    C.Post('/v1/customers', P);
  except
    on E: EStripeError do
    begin
      Raised_ := True;
      AssertEqual(E.Type_, 'invalid_request_error', 'Stripe''s type');
      AssertEqual(E.Status, 400, 'a 400');
    end;
  end;
  AssertTrue(Raised_, 'a misspelled parameter is refused');
end;

begin
  Group('Stripe-Signature');
  Test('stripe-python''s verdict on every vector', @TestSignatureVectors);
  Test('a header it makes is one it accepts', @TestSignatureHeaderRoundTrip);
  Group('the client');
  Test('a form in order, encoded', @TestParamsEncode);
  Test('what a request carries', @TestClientSends);
  Test('Stripe''s errors, and which are worth a retry', @TestClientErrors);
  Test('no secret sends nothing', @TestNoSecret);
  Test('the headers on the wire', @TestOnTheWire);
  Group('billing');
  Test('one customer per user', @TestCustomerOnce);
  Test('a checkout', @TestCheckout);
  Test('the portal', @TestPortal);
  Test('cancel applies the reply at once', @TestCancelAppliesReply);
  Group('webhooks');
  Test('a subscription, once', @TestWebhookCreates);
  Test('what is refused', @TestWebhookRefuses);
  Test('an older event does not overwrite a newer', @TestWebhookOrder);
  Test('trial, grace and the end', @TestWebhookTrialGraceCancel);
  Test('a late webhook: the row''s own times answer', @TestLateWebhook);
  Test('a failure rolls back, and the retry applies', @TestWebhookRollsBack);
  Test('payments', @TestWebhookPayments);
  Test('a customer nobody here has', @TestWebhookUnknownCustomer);
  Group('stripe-mock');
  Test('every request the plugin makes, accepted', @TestStripeMock);
  RunTestsAndHalt;
end.
