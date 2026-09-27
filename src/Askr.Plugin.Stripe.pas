{ Askr.Plugin.Stripe -- the plugin: its configuration and its one route.

  Configuration, read in Configure, once the app has loaded it:

    STRIPE_SECRET              sk_test_... or sk_live_...
    STRIPE_WEBHOOK_SECRET      whsec_..., the endpoint's signing secret
    STRIPE_WEBHOOK_PATH        /stripe/webhook unless set
    STRIPE_WEBHOOK_TOLERANCE   seconds a signature stays good; 300
    STRIPE_BASE_URL            api.stripe.com unless set; stripe-mock in tests

  **A missing secret does not stop the app.** It is logged at start, and
  every call to Stripe raises and names the variable. An app has to be
  able to run its migrations and its tests before it has a Stripe
  account, and `askr migrate` starts the plugins like the server does.

  **A missing webhook secret refuses every webhook**, with a 500 and a
  line in the log, rather than accepting them unverified. A 500 makes
  Stripe try again later, so nothing is lost while it is being set.

  The route is exempt from CSRF: Stripe cannot send a token, and the
  signature is what CSRF would have been. }
unit Askr.Plugin.Stripe;

{$mode Delphi}{$H+}

interface

uses
  SysUtils,
  Askr.Core.Text, Askr.Core.Config, Askr.Core.Clock, Askr.Core.Log,
  Askr.Http.Router, Askr.Http.Request, Askr.Http.Response, Askr.Csrf,
  Askr.Urd.Model, Askr.Plugins, Askr.Auth,
  Askr.Plugin.Stripe.Client, Askr.Plugin.Stripe.Signature,
  Askr.Plugin.Stripe.Billing;

type
  TStripePlugin = class(TPlugin)
  public
    function Name: string; override;
    procedure Configure; override;
    procedure Routes(R: TRouter); override;
  end;

{ The route's handler, exposed so a test can drive it through a router of
  its own. }
function StripeWebhook(Req: TRequest): TResponse;

{ For a handler behind a subscription. nil when the signed-in user has a
  valid one -- to Price, when a price is given -- and otherwise the answer
  to give: a 402 problem document to a JSON client, Inertia's own 409 with
  X-Inertia-Location to an Inertia visit, and a 303 to PricingPath for a
  browser.

      R := RequireSubscribed('price_...');
      if R <> nil then Exit(R);

  The shape of RequireVerified, with one difference: nobody signed in is
  refused here too. RequireVerified leaves that to RequireAuth; a paid page
  that opened because someone forgot RequireAuth is a paid page given
  away. }
function RequireSubscribed(const Price: string = '';
  const PricingPath: string = '/pricing'): TResponse;

{ What Configure read. For a test, and for a page that wants to show
  whether billing is set up -- never the secrets themselves. }
function StripeWebhookPath: string;
function StripeWebhookConfigured: Boolean;
procedure SetStripeWebhookSecret(const Secret: string;
  Tolerance: Int64 = DefaultStripeTolerance);

implementation

var
  GWebhookSecret: string = '';
  GTolerance: Int64 = DefaultStripeTolerance;
  GPath: string = '/stripe/webhook';

function StripeWebhookPath: string;
begin
  Result := GPath;
end;

function StripeWebhookConfigured: Boolean;
begin
  Result := GWebhookSecret <> '';
end;

procedure SetStripeWebhookSecret(const Secret: string; Tolerance: Int64);
begin
  GWebhookSecret := Secret;
  GTolerance := Tolerance;
end;

function RequireSubscribed(const Price, PricingPath: string): TResponse;
var
  Req: TRequest;
begin
  { Nobody signed in has the id '', and no subscription row does: one
    without a user is refused where it is written. So this is the check
    for that case too. }
  if Subscribed(Askr.Auth.Id, Price) then
    Exit(nil);
  Req := CurrentRequest;
  if (Req <> nil) and Req.AcceptsJson then
    Exit(Problem(402, 'A subscription is required.'));
  if (Req <> nil) and (Req.Header('X-Inertia').Len > 0) then
  begin
    Result := RespondText('', 409);
    Result.WithHeader('X-Inertia-Location', PricingPath);
    Exit;
  end;
  Result := Redirect(PricingPath, 303);
end;

function TStripePlugin.Name: string;
begin
  Result := 'stripe';
end;

procedure TStripePlugin.Configure;
var
  Secret: string;
begin
  Secret := Cfg('stripe.secret', '');
  SetStripe(TStripeClient.Create(Secret, Cfg('stripe.base.url', '')));
  GWebhookSecret := Cfg('stripe.webhook.secret', '');
  GTolerance := CfgInt('stripe.webhook.tolerance', DefaultStripeTolerance);
  { 0 would turn the time check off, and a replayed webhook would be as
    good as a new one. Nobody means that by setting it. }
  if GTolerance <= 0 then
    GTolerance := DefaultStripeTolerance;
  GPath := Cfg('stripe.webhook.path', '/stripe/webhook');
  if Secret = '' then
    LogWarn('stripe: STRIPE_SECRET is not set; calls to Stripe will fail ' +
      'until it is');
  if GWebhookSecret = '' then
    LogWarn('stripe: STRIPE_WEBHOOK_SECRET is not set; webhooks will be ' +
      'refused until it is');
end;

procedure TStripePlugin.Routes(R: TRouter);
begin
  CsrfExempt(GPath);
  R.Post(GPath, StripeWebhook);
end;

function StripeWebhook(Req: TRequest): TResponse;
var
  Payload: string;
  Check: TStripeSignatureCheck;
begin
  if GWebhookSecret = '' then
  begin
    LogError('stripe: a webhook arrived and STRIPE_WEBHOOK_SECRET is not ' +
      'set; refused, and Stripe will send it again');
    Exit(RespondText('webhook secret not configured', 500));
  end;

  { The body as it arrived: the signature is over these bytes, and JSON
    parsed and written out again would be a different string. }
  Payload := Req.Body.ToString;
  Check := VerifyStripeSignature(Payload,
    Req.Header('Stripe-Signature').ToString, GWebhookSecret, GTolerance,
    UnixNow);
  if Check <> scOk then
  begin
    { The reason goes to the log, not to whoever sent it. }
    LogWarn('stripe: webhook refused', ['reason', SignatureCheckName(Check)]);
    Exit(RespondText('invalid signature', 400));
  end;

  if CurrentDb = nil then
  begin
    LogError('stripe: a webhook arrived with no database connection; ' +
      'is DATABASE_URL set?');
    Exit(RespondText('no database', 500));
  end;

  try
    HandleStripeEvent(CurrentDb, Payload);
  except
    on E: EStripeWebhookError do
    begin
      LogWarn('stripe: webhook refused', ['reason', E.Message]);
      Exit(RespondText('not an event', 400));
    end;
    on E: Exception do
    begin
      { Rolled back already. A 500 makes Stripe send it again. }
      LogException(E, 'stripe webhook');
      Exit(RespondText('failed; Stripe will retry', 500));
    end;
  end;
  Result := RespondJson('{"received":true}');
end;

initialization
  RegisterPlugin(TStripePlugin);

end.
