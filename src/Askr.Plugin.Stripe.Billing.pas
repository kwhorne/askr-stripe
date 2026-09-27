{ Askr.Plugin.Stripe.Billing -- a customer per user, Checkout, the portal,
  and what a webhook changes.

  The framework does not own the user model, so a Stripe customer is keyed
  by the user id as text: the id Login takes, the way API tokens are.

  **The tables are what Stripe said, not what we asked for.** A checkout,
  a cancel or a resume sends the request and the row follows the reply or
  the webhook. Nothing here writes a status Stripe has not sent.

  **A webhook is handled in the request, in one transaction.** The event
  id goes into stripe_events first; a second delivery of the same event
  meets the unique index and changes nothing. If anything after that
  fails, the transaction rolls back, the route answers 500, and Stripe
  sends it again -- for up to three days. That is the queue, and it needs
  nothing from the app: a new Askr app has no queue configured. A listener
  that has slow work to do can be registered with ListenQueued.

  **Stripe does not promise order.** customer.subscription.updated can
  arrive before .created. Each subscription row keeps synced_at, the
  Stripe time of what it last applied, and an older event does not
  overwrite a newer state. It is still recorded and still dispatched:
  the listeners hear every event once, and the table holds the latest.

  **Money is minor units, as Stripe counts it**: an Int64 of øre or cents.
  It goes into Currency by assignment, never by a cast. }
unit Askr.Plugin.Stripe.Billing;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json, Askr.Core.Clock,
  Askr.Core.Log, Askr.Urd.Driver, Askr.Urd.Model, Askr.Events,
  Askr.Plugin.Stripe.Client;

type
  EStripeWebhookError = class(Exception);

  TStripeSubscription = record
    StripeId: string;
    UserId: string;
    Customer: string;
    Status: string;
    { The first item's price. Prices has every item's, and ItemIds their
      si_... ids, in the same order: Stripe changes an item by its id. }
    Price: string;
    Prices: TStringArray;
    ItemIds: TStringArray;
    Quantity: Integer;
    { Unix seconds, as Stripe writes them; 0 when there is none. }
    TrialEnd: Int64;
    CurrentPeriodEnd: Int64;
    CancelAt: Int64;
    EndedAt: Int64;
    CancelAtPeriodEnd: Boolean;
    { Active or trialing. A cancelled subscription stays active until the
      period it was paid for ends, so this covers the grace period too.
      past_due is not valid: the payment failed. }
    function Valid: Boolean;
    function OnTrial(NowUnix: Int64): Boolean;
    { Cancelled, and still running to the end of what was paid for. }
    function OnGracePeriod(NowUnix: Int64): Boolean;
    function HasPrice(const APrice: string): Boolean;
  end;

  TCheckoutMode = (cmSubscription, cmPayment);

  TCheckout = record
    Mode: TCheckoutMode;
    Prices: array of string;
    Quantities: array of Integer;
    SuccessUrl: string;
    CancelUrl: string;
    TrialDays: Integer;
    AllowPromotionCodes: Boolean;
    { For a retry that must not make a second session. }
    IdempotencyKey: string;
    { Anything else Checkout takes, in Stripe's own names, sent after the
      fields above: C.Extra.Add('payment_method_collection', 'if_required').
      Checkout has dozens of parameters; a field for each here would be a
      second copy of Stripe's reference that is always behind it. }
    Extra: TStripeParams;
    procedure Add(const Price: string; Quantity: Integer = 1);
  end;

  TWebhookOutcome = (woHandled, woDuplicate);

  { Every event Stripe sends, verified, once. For the types this plugin
    does not turn into something of its own. Payload is the whole event
    as JSON. }
  TStripeEventReceived = class(TEvent)
  private
    FEventId, FEventType, FPayload: string;
  published
    property EventId: string read FEventId write FEventId;
    property EventType: string read FEventType write FEventType;
    property Payload: string read FPayload write FPayload;
  end;

  TStripeSubscriptionEvent = class(TEvent)
  private
    FUserId, FSubscriptionId, FStatus, FPrice: string;
  published
    property UserId: string read FUserId write FUserId;
    property SubscriptionId: string read FSubscriptionId write FSubscriptionId;
    property Status: string read FStatus write FStatus;
    property Price: string read FPrice write FPrice;
  end;

  TStripeSubscriptionCreated = class(TStripeSubscriptionEvent);
  TStripeSubscriptionUpdated = class(TStripeSubscriptionEvent);
  { customer.subscription.deleted: it has ended, not merely been set to
    end. A cancel at the period's end is an Updated with
    cancel_at_period_end, and then this, when the period is over. }
  TStripeSubscriptionCancelled = class(TStripeSubscriptionEvent);

  { A one-off Checkout payment that has been paid: checkout.session
    .completed with payment_status paid, or .async_payment_succeeded for
    the methods that settle later. }
  TStripePaymentSucceeded = class(TEvent)
  private
    FUserId, FSessionId, FPaymentIntent, FCurrency: string;
    FAmountTotal: Int64;
  published
    property UserId: string read FUserId write FUserId;
    property SessionId: string read FSessionId write FSessionId;
    property PaymentIntent: string read FPaymentIntent write FPaymentIntent;
    { Minor units: 12900 is 129.00. }
    property AmountTotal: Int64 read FAmountTotal write FAmountTotal;
    property Currency: string read FCurrency write FCurrency;
  end;

  { invoice.payment_failed: a renewal did not go through. Stripe retries
    by its own schedule; this is the moment to tell the user. }
  TStripePaymentFailed = class(TEvent)
  private
    FUserId, FInvoiceId, FSubscriptionId, FCurrency: string;
    FAmountDue: Int64;
  published
    property UserId: string read FUserId write FUserId;
    property InvoiceId: string read FInvoiceId write FInvoiceId;
    property SubscriptionId: string read FSubscriptionId write FSubscriptionId;
    property AmountDue: Int64 read FAmountDue write FAmountDue;
    property Currency: string read FCurrency write FCurrency;
  end;

{ The client every call below goes through. The plugin sets it in
  Configure; a test sets its own. SetStripe takes ownership. }
procedure SetStripe(C: TStripeClient);
function Stripe: TStripeClient;

function SubscriptionCheckout(const Price, SuccessUrl,
  CancelUrl: string): TCheckout;
function PaymentCheckout(const Price: string; Quantity: Integer;
  const SuccessUrl, CancelUrl: string): TCheckout;

{ The user's Stripe customer id, or ''. }
function StripeCustomerId(const UserId: string): string;
{ The user's Stripe customer, made the first time. Two requests racing to
  make one can both make one in Stripe; the row decides, and the loser
  deletes its own. }
function EnsureStripeCustomer(const UserId, Email: string;
  const Name: string = ''): string;

{ Where to send the user: a Checkout session's url. }
function CheckoutUrl(const UserId, Email: string; const C: TCheckout): string;
{ Stripe's customer portal, for a card, a plan or a cancellation. }
function BillingPortalUrl(const UserId, ReturnUrl: string): string;

{ The user's subscription that matters: a valid one if there is one,
  otherwise the newest. }
function FindSubscription(const UserId: string;
  out S: TStripeSubscription): Boolean;
{ A valid subscription, to Price when one is given. }
function Subscribed(const UserId: string; const Price: string = ''): Boolean;
function OnTrial(const UserId: string): Boolean;
function OnGracePeriod(const UserId: string): Boolean;

{ Cancel at the end of the period that has been paid for; take that back;
  or end it now. Each applies Stripe's reply to the table at once, so the
  next page shows it without waiting for the webhook. Raises when the user
  has no valid subscription. }
procedure CancelSubscription(const UserId: string);
procedure ResumeSubscription(const UserId: string);
procedure CancelSubscriptionNow(const UserId: string);

{ A verified webhook's body, applied. Raises EStripeWebhookError when the
  body is not an event, and whatever the database or a listener raised
  otherwise -- after rolling back. }
function HandleStripeEvent(Db: TDbConnection;
  const Payload: string): TWebhookOutcome;

implementation

const
  { The one list of what counts as subscribed: TStripeSubscription.Valid
    asks it, and the SQL in Subscribed is built from it. }
  ValidStatuses: array[0..1] of string = ('active', 'trialing');

var
  GStripe: TStripeClient = nil;

function ValidStatusSql: string;
var
  I: Integer;
begin
  Result := '(';
  for I := 0 to High(ValidStatuses) do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + '''' + ValidStatuses[I] + '''';
  end;
  Result := Result + ')';
end;

procedure SetStripe(C: TStripeClient);
begin
  if C = GStripe then
    Exit;
  GStripe.Free;
  GStripe := C;
end;

function Stripe: TStripeClient;
begin
  if GStripe = nil then
    raise EStripeError.Create(0, 'config', '', '', '', '',
      'The Stripe plugin has not been started. UsePlugins(R) in app.lpr ' +
      'starts it; a test calls SetStripe.', False);
  Result := GStripe;
end;

{ ------------------------------------------------------ subscription -- }

function TStripeSubscription.Valid: Boolean;
var
  I: Integer;
begin
  for I := 0 to High(ValidStatuses) do
    if Status = ValidStatuses[I] then
      Exit(True);
  Result := False;
end;

function TStripeSubscription.OnTrial(NowUnix: Int64): Boolean;
begin
  { The time as well as the status: the webhook that ends a trial can be
    late, and a trial that ended an hour ago is not one. }
  Result := (Status = 'trialing') and (TrialEnd > NowUnix);
end;

function TStripeSubscription.OnGracePeriod(NowUnix: Int64): Boolean;
var
  Ends: Int64;
begin
  if not Valid then
    Exit(False);
  if not CancelAtPeriodEnd and (CancelAt = 0) then
    Exit(False);
  if CancelAt > 0 then
    Ends := CancelAt
  else
    Ends := CurrentPeriodEnd;
  Result := Ends > NowUnix;
end;

function TStripeSubscription.HasPrice(const APrice: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Prices) do
    if Prices[I] = APrice then
      Exit(True);
  Result := False;
end;

procedure TCheckout.Add(const Price: string; Quantity: Integer);
begin
  SetLength(Prices, Length(Prices) + 1);
  SetLength(Quantities, Length(Quantities) + 1);
  Prices[High(Prices)] := Price;
  Quantities[High(Quantities)] := Quantity;
end;

function SubscriptionCheckout(const Price, SuccessUrl,
  CancelUrl: string): TCheckout;
begin
  Result := Default(TCheckout);
  Result.Mode := cmSubscription;
  Result.Add(Price, 1);
  Result.SuccessUrl := SuccessUrl;
  Result.CancelUrl := CancelUrl;
end;

function PaymentCheckout(const Price: string; Quantity: Integer;
  const SuccessUrl, CancelUrl: string): TCheckout;
begin
  Result := Default(TCheckout);
  Result.Mode := cmPayment;
  Result.Add(Price, Quantity);
  Result.SuccessUrl := SuccessUrl;
  Result.CancelUrl := CancelUrl;
end;

{ ---------------------------------------------------------------- SQL -- }

function NeedDb: TDbConnection;
begin
  Result := CurrentDb;
  if Result = nil then
    raise EDbError.Create(
      'The Stripe plugin needs a database connection. A generated app ' +
      'leases one per request when DATABASE_URL is set; a test calls UseDb.');
end;

function Ph(Db: TDbConnection; A: TArena; Index: Integer): string;
var
  B: TStrBuilder;
begin
  B.Init(A, 8);
  Db.AppendPlaceholder(B, Index);
  Result := B.ToString;
end;

{ 0 is Stripe's "none" for a time, and NULL is the database's. }
function TimeParam(A: TArena; V: Int64): TDbParam;
begin
  if V = 0 then
    Result := DbNull
  else
    Result := DbParam(A, V);
end;

function IntOrZero(R: TDbResult; Row, Col: Integer): Int64;
begin
  if R.IsNull(Row, Col) then
    Result := 0
  else
    Result := R.AsInt64(Row, Col);
end;

function StripeCustomerId(const UserId: string): string;
var
  Db: TDbConnection;
  A: TArena;
  R: TDbResult;
begin
  Result := '';
  Db := NeedDb;
  A := TArena.Create(4096);
  try
    R := Db.ExecParams(A, 'SELECT stripe_id FROM stripe_customers ' +
      'WHERE user_id = ' + Ph(Db, A, 1), [DbParam(A, UserId)]);
    if (R <> nil) and not R.IsEmpty then
      Result := R.Value(0, 0).ToString;
  finally
    A.Free;
  end;
end;

function UserForCustomer(Db: TDbConnection; const Customer: string): string;
var
  A: TArena;
  R: TDbResult;
begin
  Result := '';
  if Customer = '' then
    Exit;
  A := TArena.Create(4096);
  try
    R := Db.ExecParams(A, 'SELECT user_id FROM stripe_customers ' +
      'WHERE stripe_id = ' + Ph(Db, A, 1), [DbParam(A, Customer)]);
    if (R <> nil) and not R.IsEmpty then
      Result := R.Value(0, 0).ToString;
  finally
    A.Free;
  end;
end;

function EnsureStripeCustomer(const UserId, Email, Name: string): string;
var
  Db: TDbConnection;
  A: TArena;
  P: TStripeParams;
  Reply: string;
begin
  if Trim(UserId) = '' then
    raise EStripeError.Create(0, 'config', '', '', '', '',
      'A Stripe customer needs a user id.', False);
  Result := StripeCustomerId(UserId);
  if Result <> '' then
    Exit;

  P := Default(TStripeParams);
  if Email <> '' then
    P.Add('email', Email);
  if Name <> '' then
    P.Add('name', Name);
  { The way back from Stripe's side: a customer made here says whose it
    is, in the dashboard and in every webhook about it. }
  P.Add('metadata[askr_user_id]', UserId);
  { A random key, not one made from the user id. Stripe keeps a key for
    24 hours across everything that shares the account, so a key of the
    user id handed a deleted customer back to a database that had been
    reset, and would hand user 7 of the staging app the customer of user
    7 of the dev app. The first run against a real account found it. }
  Reply := Stripe.Post('/v1/customers', P);
  Result := StripeField(Reply, 'id');
  if Result = '' then
    raise EStripeError.Create(0, 'api_error', '', '', '', Stripe.LastRequestId,
      'Stripe made a customer and did not say its id.', False);

  Db := NeedDb;
  A := TArena.Create(4096);
  try
    try
      Db.ExecParams(A, 'INSERT INTO stripe_customers ' +
        '(user_id, stripe_id, created_at) VALUES (' + Ph(Db, A, 1) + ', ' +
        Ph(Db, A, 2) + ', ' + Ph(Db, A, 3) + ')',
        [DbParam(A, UserId), DbParam(A, Result), DbParam(A, UnixNow)]);
    except
      on E: EDbError do
      begin
        { Another request made the row first, with a customer of its
          own. Theirs is kept; ours is deleted in Stripe, so the account
          does not collect customers nobody points at. }
        if not E.IsUniqueViolation or Db.InTransaction then
          raise;
        Stripe.Delete('/v1/customers/' + Result);
        Result := StripeCustomerId(UserId);
      end;
    end;
  finally
    A.Free;
  end;
end;

function CheckoutUrl(const UserId, Email: string; const C: TCheckout): string;
var
  P: TStripeParams;
  Customer, Reply: string;
  I: Integer;
begin
  if Length(C.Prices) = 0 then
    raise EStripeError.Create(0, 'config', '', '', '', '',
      'A checkout needs at least one price.', False);
  if C.SuccessUrl = '' then
    raise EStripeError.Create(0, 'config', '', '', '', '',
      'A checkout needs a success url: where Stripe sends the user after ' +
      'paying.', False);
  Customer := EnsureStripeCustomer(UserId, Email);

  P := Default(TStripeParams);
  case C.Mode of
    cmSubscription: P.Add('mode', 'subscription');
    cmPayment: P.Add('mode', 'payment');
  end;
  P.Add('customer', Customer);
  P.Add('client_reference_id', UserId);
  for I := 0 to High(C.Prices) do
  begin
    P.Add('line_items[' + IntToStr(I) + '][price]', C.Prices[I]);
    P.Add('line_items[' + IntToStr(I) + '][quantity]', C.Quantities[I]);
  end;
  P.Add('success_url', C.SuccessUrl);
  if C.CancelUrl <> '' then
    P.Add('cancel_url', C.CancelUrl);
  if C.AllowPromotionCodes then
    P.AddBool('allow_promotion_codes', True);
  P.Add('metadata[askr_user_id]', UserId);
  if C.Mode = cmSubscription then
  begin
    { On the subscription too, so a webhook about it can find the user
      even for a customer this app did not make. }
    P.Add('subscription_data[metadata][askr_user_id]', UserId);
    if C.TrialDays > 0 then
      P.Add('subscription_data[trial_period_days]', C.TrialDays);
  end
  else if C.TrialDays > 0 then
    raise EStripeError.Create(0, 'config', '', '', '', '',
      'A trial belongs to a subscription, not to a payment.', False);
  P.Append(C.Extra);

  Reply := Stripe.Post('/v1/checkout/sessions', P, C.IdempotencyKey);
  Result := StripeField(Reply, 'url');
end;

function BillingPortalUrl(const UserId, ReturnUrl: string): string;
var
  P: TStripeParams;
  Customer: string;
begin
  Customer := StripeCustomerId(UserId);
  if Customer = '' then
    raise EStripeError.Create(0, 'config', '', '', '', '',
      'This user has no Stripe customer yet, so there is no portal to ' +
      'send them to. A checkout makes one.', False);
  P := Default(TStripeParams);
  P.Add('customer', Customer);
  if ReturnUrl <> '' then
    P.Add('return_url', ReturnUrl);
  Result := StripeField(Stripe.Post('/v1/billing_portal/sessions', P), 'url');
end;

{ ------------------------------------------------------------ reading -- }

const
  SubColumns = 'stripe_id, user_id, customer, status, price, quantity, ' +
    'trial_end, current_period_end, cancel_at, ended_at, ' +
    'cancel_at_period_end';

procedure ReadItems(Db: TDbConnection; var S: TStripeSubscription);
var
  A: TArena;
  R: TDbResult;
  I: Integer;
begin
  S.Prices := nil;
  S.ItemIds := nil;
  A := TArena.Create(4096);
  try
    R := Db.ExecParams(A, 'SELECT price, stripe_id FROM stripe_subscription_items ' +
      'WHERE subscription = ' + Ph(Db, A, 1) + ' ORDER BY id',
      [DbParam(A, S.StripeId)]);
    if R = nil then
      Exit;
    SetLength(S.Prices, R.RowCount);
    SetLength(S.ItemIds, R.RowCount);
    for I := 0 to R.RowCount - 1 do
    begin
      S.Prices[I] := R.Value(I, 0).ToString;
      S.ItemIds[I] := R.Value(I, 1).ToString;
    end;
  finally
    A.Free;
  end;
end;

procedure ReadSub(R: TDbResult; Row: Integer; var S: TStripeSubscription);
var
  B: Boolean;
begin
  S := Default(TStripeSubscription);
  S.StripeId := R.Value(Row, 0).ToString;
  S.UserId := R.Value(Row, 1).ToString;
  S.Customer := R.Value(Row, 2).ToString;
  S.Status := R.Value(Row, 3).ToString;
  S.Price := R.Value(Row, 4).ToString;
  S.Quantity := Integer(IntOrZero(R, Row, 5));
  S.TrialEnd := IntOrZero(R, Row, 6);
  S.CurrentPeriodEnd := IntOrZero(R, Row, 7);
  S.CancelAt := IntOrZero(R, Row, 8);
  S.EndedAt := IntOrZero(R, Row, 9);
  B := False;
  if not R.IsNull(Row, 10) then
    SqlToBool(R.Value(Row, 10), B);
  S.CancelAtPeriodEnd := B;
end;

function FindSubscription(const UserId: string;
  out S: TStripeSubscription): Boolean;
var
  Db: TDbConnection;
  A: TArena;
  R: TDbResult;
  I, Pick: Integer;
begin
  S := Default(TStripeSubscription);
  Db := NeedDb;
  A := TArena.Create(8192);
  try
    R := Db.ExecParams(A, 'SELECT ' + SubColumns +
      ' FROM stripe_subscriptions WHERE user_id = ' + Ph(Db, A, 1) +
      ' ORDER BY id DESC', [DbParam(A, UserId)]);
    if (R = nil) or R.IsEmpty then
      Exit(False);
    Pick := 0;
    for I := 0 to R.RowCount - 1 do
    begin
      ReadSub(R, I, S);
      if S.Valid then
      begin
        Pick := I;
        Break;
      end;
    end;
    ReadSub(R, Pick, S);
  finally
    A.Free;
  end;
  ReadItems(Db, S);
  Result := True;
end;

function Subscribed(const UserId, Price: string): Boolean;
var
  Db: TDbConnection;
  A: TArena;
  R: TDbResult;
begin
  Db := NeedDb;
  A := TArena.Create(4096);
  try
    if Price = '' then
      R := Db.ExecParams(A, 'SELECT 1 FROM stripe_subscriptions ' +
        'WHERE user_id = ' + Ph(Db, A, 1) +
        ' AND status IN ' + ValidStatusSql, [DbParam(A, UserId)])
    else
      R := Db.ExecParams(A, 'SELECT 1 FROM stripe_subscriptions s ' +
        'JOIN stripe_subscription_items i ON i.subscription = s.stripe_id ' +
        'WHERE s.user_id = ' + Ph(Db, A, 1) + ' AND i.price = ' +
        Ph(Db, A, 2) + ' AND s.status IN ' + ValidStatusSql,
        [DbParam(A, UserId), DbParam(A, Price)]);
    Result := (R <> nil) and not R.IsEmpty;
  finally
    A.Free;
  end;
end;

function OnTrial(const UserId: string): Boolean;
var
  S: TStripeSubscription;
begin
  Result := FindSubscription(UserId, S) and S.OnTrial(UnixNow);
end;

function OnGracePeriod(const UserId: string): Boolean;
var
  S: TStripeSubscription;
begin
  Result := FindSubscription(UserId, S) and S.OnGracePeriod(UnixNow);
end;

{ ----------------------------------------------------------- applying -- }

{ The period end moved from the subscription onto its items in Stripe's
  2025-03-31 version. The item's is read first; the subscription's is the
  fallback for an endpoint on an older version. }
function PeriodEnd(Sub, FirstItem: PJsonValue): Int64;
begin
  Result := JsonAsInt(JsonMember(FirstItem, 'current_period_end'));
  if Result = 0 then
    Result := JsonAsInt(JsonMember(Sub, 'current_period_end'));
end;

function MetadataUser(Obj: PJsonValue): string;
begin
  Result := JsonAsString(JsonMember(JsonMember(Obj, 'metadata'),
    'askr_user_id'));
end;

{ Writes Sub -- a subscription object as Stripe sends it -- unless the row
  holds something newer than SyncedAt. Returns the user it belongs to, or
  '' when nobody here can be found for it. }
function ApplySubscription(Db: TDbConnection; Sub: PJsonValue;
  SyncedAt: Int64; out UserId, Price: string): Boolean;
var
  A: TArena;
  R: TDbResult;
  Id, Customer, Status: string;
  Items, Item, First: PJsonValue;
  Quantity: Int64;
  I: Integer;
  Params: array[0..11] of TDbParam;
begin
  Result := False;
  Id := JsonAsString(JsonMember(Sub, 'id'));
  Customer := JsonAsString(JsonMember(Sub, 'customer'));
  Status := JsonAsString(JsonMember(Sub, 'status'));
  Items := JsonMember(JsonMember(Sub, 'items'), 'data');
  First := JsonAt(Items, 0);
  Price := JsonAsString(JsonMember(JsonMember(First, 'price'), 'id'));
  Quantity := JsonAsInt(JsonMember(First, 'quantity'), 1);
  if Id = '' then
    raise EStripeWebhookError.Create('A subscription without an id.');

  UserId := UserForCustomer(Db, Customer);
  if UserId = '' then
    UserId := MetadataUser(Sub);
  if UserId = '' then
  begin
    { A subscription made in the dashboard for a customer this app never
      made. There is nobody to give it to, and guessing would give it to
      the wrong person. }
    LogWarn('stripe: a subscription for a customer no user has',
      ['subscription', Id, 'customer', Customer]);
    Exit(False);
  end;

  A := TArena.Create(16 * 1024);
  try
    R := Db.ExecParams(A, 'SELECT synced_at FROM stripe_subscriptions ' +
      'WHERE stripe_id = ' + Ph(Db, A, 1), [DbParam(A, Id)]);
    if (R <> nil) and not R.IsEmpty and (R.AsInt64(0, 0) > SyncedAt) then
      { Older than what the row holds. }
      Exit(True);

    Params[0] := DbParam(A, UserId);
    Params[1] := DbParam(A, Customer);
    Params[2] := DbParam(A, Status);
    Params[3] := DbParam(A, Price);
    Params[4] := DbParam(A, Quantity);
    Params[5] := TimeParam(A, JsonAsInt(JsonMember(Sub, 'trial_end')));
    Params[6] := TimeParam(A, PeriodEnd(Sub, First));
    Params[7] := TimeParam(A, JsonAsInt(JsonMember(Sub, 'cancel_at')));
    Params[8] := TimeParam(A, JsonAsInt(JsonMember(Sub, 'ended_at')));
    Params[9] := DbParam(A, JsonAsBool(JsonMember(Sub, 'cancel_at_period_end')));
    Params[10] := DbParam(A, SyncedAt);
    Params[11] := DbParam(A, Id);

    { UPDATE, then INSERT when there was nothing to update: the three
      dialects spell upsert three ways. Two events for a new subscription
      at once can both find nothing; the second INSERT then meets the
      unique index, the webhook answers 500, and Stripe's retry takes the
      UPDATE. }
    R := Db.ExecParams(A, 'UPDATE stripe_subscriptions SET ' +
      'user_id = ' + Ph(Db, A, 1) + ', customer = ' + Ph(Db, A, 2) +
      ', status = ' + Ph(Db, A, 3) + ', price = ' + Ph(Db, A, 4) +
      ', quantity = ' + Ph(Db, A, 5) + ', trial_end = ' + Ph(Db, A, 6) +
      ', current_period_end = ' + Ph(Db, A, 7) + ', cancel_at = ' +
      Ph(Db, A, 8) + ', ended_at = ' + Ph(Db, A, 9) +
      ', cancel_at_period_end = ' + Ph(Db, A, 10) + ', synced_at = ' +
      Ph(Db, A, 11) + ' WHERE stripe_id = ' + Ph(Db, A, 12), Params);
    if (R = nil) or (R.AffectedRows <= 0) then
      Db.ExecParams(A, 'INSERT INTO stripe_subscriptions (user_id, ' +
        'customer, status, price, quantity, trial_end, current_period_end, ' +
        'cancel_at, ended_at, cancel_at_period_end, synced_at, stripe_id) ' +
        'VALUES (' + Ph(Db, A, 1) + ', ' + Ph(Db, A, 2) + ', ' +
        Ph(Db, A, 3) + ', ' + Ph(Db, A, 4) + ', ' + Ph(Db, A, 5) + ', ' +
        Ph(Db, A, 6) + ', ' + Ph(Db, A, 7) + ', ' + Ph(Db, A, 8) + ', ' +
        Ph(Db, A, 9) + ', ' + Ph(Db, A, 10) + ', ' + Ph(Db, A, 11) + ', ' +
        Ph(Db, A, 12) + ')', Params);

    { The items are the subscription's as it is now: an item removed in
      the portal is gone from the next event, and from here. }
    Db.ExecParams(A, 'DELETE FROM stripe_subscription_items ' +
      'WHERE subscription = ' + Ph(Db, A, 1), [DbParam(A, Id)]);
    if Items <> nil then
    for I := 0 to Items^.Count - 1 do
    begin
      Item := JsonAt(Items, I);
      Db.ExecParams(A, 'INSERT INTO stripe_subscription_items ' +
        '(stripe_id, subscription, price, quantity) VALUES (' +
        Ph(Db, A, 1) + ', ' + Ph(Db, A, 2) + ', ' + Ph(Db, A, 3) + ', ' +
        Ph(Db, A, 4) + ')', [
        DbParam(A, JsonAsString(JsonMember(Item, 'id'))),
        DbParam(A, Id),
        DbParam(A, JsonAsString(JsonMember(JsonMember(Item, 'price'), 'id'))),
        DbParam(A, JsonAsInt(JsonMember(Item, 'quantity'), 1))]);
    end;
  finally
    A.Free;
  end;
  Result := True;
end;

{ A reply from the subscriptions API, applied now. Stripe's clock and ours
  agree to the second or so; the webhook for the same change, created in
  the same second, applies the same state again. }
procedure ApplyReply(const Json: string);
var
  A: TArena;
  Root: PJsonValue;
  ErrPos: SizeInt;
  UserId, Price: string;
begin
  A := TArena.Create(Length(Json) * 4 + 16 * 1024);
  try
    if not JsonParse(A, Str(Json), Root, ErrPos) then
      raise EStripeError.Create(0, 'api_error', '', '', '', '',
        'Stripe answered with something that is not JSON.', False);
    ApplySubscription(NeedDb, Root, UnixNow, UserId, Price);
  finally
    A.Free;
  end;
end;

function ValidSubscriptionId(const UserId: string): string;
var
  S: TStripeSubscription;
begin
  if not FindSubscription(UserId, S) or not S.Valid then
    raise EStripeError.Create(0, 'config', '', '', '', '',
      'This user has no active subscription.', False);
  Result := S.StripeId;
end;

procedure SetCancelAtPeriodEnd(const UserId: string; Value: Boolean);
var
  P: TStripeParams;
begin
  P := Default(TStripeParams);
  P.AddBool('cancel_at_period_end', Value);
  ApplyReply(Stripe.Post('/v1/subscriptions/' + ValidSubscriptionId(UserId), P));
end;

procedure CancelSubscription(const UserId: string);
begin
  SetCancelAtPeriodEnd(UserId, True);
end;

procedure ResumeSubscription(const UserId: string);
begin
  SetCancelAtPeriodEnd(UserId, False);
end;

procedure CancelSubscriptionNow(const UserId: string);
begin
  ApplyReply(Stripe.Delete('/v1/subscriptions/' + ValidSubscriptionId(UserId)));
end;

{ ----------------------------------------------------------- webhooks -- }

procedure DispatchSubscription(AClass: TEventClass; const UserId: string;
  Sub: PJsonValue; const Price: string);
var
  E: TStripeSubscriptionEvent;
begin
  E := TStripeSubscriptionEvent(AClass.Create);
  E.UserId := UserId;
  E.SubscriptionId := JsonAsString(JsonMember(Sub, 'id'));
  E.Status := JsonAsString(JsonMember(Sub, 'status'));
  E.Price := Price;
  DispatchEvent(E);
end;

procedure PaymentSucceeded(Db: TDbConnection; Session: PJsonValue);
var
  E: TStripePaymentSucceeded;
  UserId: string;
begin
  UserId := JsonAsString(JsonMember(Session, 'client_reference_id'));
  if UserId = '' then
    UserId := UserForCustomer(Db,
      JsonAsString(JsonMember(Session, 'customer')));
  E := TStripePaymentSucceeded.Create;
  E.UserId := UserId;
  E.SessionId := JsonAsString(JsonMember(Session, 'id'));
  E.PaymentIntent := JsonAsString(JsonMember(Session, 'payment_intent'));
  E.AmountTotal := JsonAsInt(JsonMember(Session, 'amount_total'));
  E.Currency := JsonAsString(JsonMember(Session, 'currency'));
  DispatchEvent(E);
end;

procedure PaymentFailed(Db: TDbConnection; Invoice: PJsonValue);
var
  E: TStripePaymentFailed;
  Sub: string;
begin
  { invoice.subscription moved under parent.subscription_details in
    2025-03-31, the same version that moved the period end. Both are
    read. }
  Sub := JsonAsString(JsonMember(JsonMember(JsonMember(Invoice, 'parent'),
    'subscription_details'), 'subscription'));
  if Sub = '' then
    Sub := JsonAsString(JsonMember(Invoice, 'subscription'));
  E := TStripePaymentFailed.Create;
  E.UserId := UserForCustomer(Db,
    JsonAsString(JsonMember(Invoice, 'customer')));
  E.InvoiceId := JsonAsString(JsonMember(Invoice, 'id'));
  E.SubscriptionId := Sub;
  E.AmountDue := JsonAsInt(JsonMember(Invoice, 'amount_due'));
  E.Currency := JsonAsString(JsonMember(Invoice, 'currency'));
  DispatchEvent(E);
end;

procedure Apply(Db: TDbConnection; const EventType: string; Created: Int64;
  Obj: PJsonValue);
var
  UserId, Price: string;
begin
  if (EventType = 'customer.subscription.created') or
     (EventType = 'customer.subscription.updated') or
     (EventType = 'customer.subscription.deleted') or
     (EventType = 'customer.subscription.paused') or
     (EventType = 'customer.subscription.resumed') or
     (EventType = 'customer.subscription.trial_will_end') then
  begin
    if not ApplySubscription(Db, Obj, Created, UserId, Price) then
      Exit;
    if EventType = 'customer.subscription.created' then
      DispatchSubscription(TStripeSubscriptionCreated, UserId, Obj, Price)
    else if EventType = 'customer.subscription.deleted' then
      DispatchSubscription(TStripeSubscriptionCancelled, UserId, Obj, Price)
    else
      DispatchSubscription(TStripeSubscriptionUpdated, UserId, Obj, Price);
  end
  else if EventType = 'checkout.session.completed' then
  begin
    { A subscription checkout is told by the subscription's own events.
      A payment is told here -- once it is paid: a bank debit completes
      the session unpaid and settles days later. }
    if (JsonAsString(JsonMember(Obj, 'mode')) = 'payment') and
       (JsonAsString(JsonMember(Obj, 'payment_status')) = 'paid') then
      PaymentSucceeded(Db, Obj);
  end
  else if EventType = 'checkout.session.async_payment_succeeded' then
  begin
    if JsonAsString(JsonMember(Obj, 'mode')) = 'payment' then
      PaymentSucceeded(Db, Obj);
  end
  else if EventType = 'invoice.payment_failed' then
    PaymentFailed(Db, Obj);
end;

function HandleStripeEvent(Db: TDbConnection;
  const Payload: string): TWebhookOutcome;
var
  A: TArena;
  Root, Obj: PJsonValue;
  ErrPos: SizeInt;
  Id, EventType: string;
  Created: Int64;
  OwnTx: Boolean;
  Received: TStripeEventReceived;
begin
  A := TArena.Create(Length(Payload) * 4 + 16 * 1024);
  try
    if not JsonParse(A, Str(Payload), Root, ErrPos) or
       (JsonAsString(JsonMember(Root, 'object')) <> 'event') then
      raise EStripeWebhookError.Create('The body is not a Stripe event.');
    Id := JsonAsString(JsonMember(Root, 'id'));
    EventType := JsonAsString(JsonMember(Root, 'type'));
    Created := JsonAsInt(JsonMember(Root, 'created'));
    Obj := JsonMember(JsonMember(Root, 'data'), 'object');
    if (Id = '') or (EventType = '') then
      raise EStripeWebhookError.Create('The event has no id or no type.');

    OwnTx := not Db.InTransaction;
    if OwnTx then
      Db.StartTransaction;
    try
      try
        Db.ExecParams(A, 'INSERT INTO stripe_events (stripe_id, type, ' +
          'created, received_at) VALUES (' + Ph(Db, A, 1) + ', ' +
          Ph(Db, A, 2) + ', ' + Ph(Db, A, 3) + ', ' + Ph(Db, A, 4) + ')',
          [DbParam(A, Id), DbParam(A, EventType), DbParam(A, Created),
           DbParam(A, UnixNow)]);
      except
        on E: EDbError do
        begin
          if not E.IsUniqueViolation then
            raise;
          { Delivered before. Nothing happens twice. }
          if OwnTx then
            Db.Rollback;
          OwnTx := False;
          Exit(woDuplicate);
        end;
      end;

      Apply(Db, EventType, Created, Obj);

      Received := TStripeEventReceived.Create;
      Received.EventId := Id;
      Received.EventType := EventType;
      Received.Payload := Payload;
      DispatchEvent(Received);

      if OwnTx then
        Db.Commit;
      OwnTx := False;
    except
      if OwnTx then
        Db.Rollback;
      raise;
    end;
  finally
    A.Free;
  end;
  Result := woHandled;
end;

initialization
  RegisterEvent(TStripeEventReceived);
  RegisterEvent(TStripeSubscriptionCreated);
  RegisterEvent(TStripeSubscriptionUpdated);
  RegisterEvent(TStripeSubscriptionCancelled);
  RegisterEvent(TStripePaymentSucceeded);
  RegisterEvent(TStripePaymentFailed);

finalization
  SetStripe(nil);

end.
