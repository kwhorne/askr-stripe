{ Askr.Plugin.Stripe.Client -- Stripe's HTTP API, and nothing above it.

  Stripe takes form-encoded bodies, not JSON: nested fields are written
  line_items[0][price]=..., in the order they were added. It answers with
  JSON, and an error is an object under "error" with type, code, message
  and param.

  Four headers go with every request:

  * Authorization: Bearer <secret>. The secret is never logged, never in
    an error and never in Describe.
  * Stripe-Version, pinned. Without it the account's default version
    decides the shape of every reply, and that default moves when someone
    clicks a button in the dashboard. The pin is the version stripe-python
    pinned when this was written; the webhook endpoint has to be created
    with the same one, because a webhook's payload follows the endpoint's
    version and not the request's.
  * Idempotency-Key on every POST. The caller's, when it has one that
    survives a retry -- a queue job's id -- and a random one otherwise,
    which is what Stripe's own libraries send. Only the caller's key
    covers the case that actually happens: a job that fails after Stripe
    accepted the request and is run again.
  * Content-Type: application/x-www-form-urlencoded on a POST.

  Retryable follows the Stripe-Should-Retry header when Stripe sends one,
  as Stripe's libraries do. Without it: 409 (a concurrent request with the
  same key), 429 and 5xx are worth another try, and nothing else becomes
  more correct by being sent again. }
unit Askr.Plugin.Stripe.Client;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes,
  Askr.Core.Arena, Askr.Core.Text, Askr.Core.Json, Askr.Core.Crypto,
  Askr.Http.Client;

const
  StripeApiVersion = '2026-08-26.dahlia';
  DefaultStripeBaseUrl = 'https://api.stripe.com';
  DefaultStripeTimeoutMs = 30000;

type
  { The error as Stripe writes it. Type_ is Stripe's own: card_error,
    invalid_request_error, api_error, idempotency_error. 'config' and
    'network' are ours, for the two failures that never reached Stripe's
    error format. }
  EStripeError = class(Exception)
  private
    FStatus: Integer;
    FType: string;
    FCode: string;
    FParam: string;
    FDeclineCode: string;
    FRequestId: string;
    FRetryable: Boolean;
  public
    constructor Create(AStatus: Integer; const AType, ACode, AParam,
      ADeclineCode, ARequestId, AMessage: string; ARetryable: Boolean);
    property Status: Integer read FStatus;
    property Type_: string read FType;
    property Code: string read FCode;
    property Param: string read FParam;
    property DeclineCode: string read FDeclineCode;
    { Stripe's Request-Id: what their dashboard finds the request by. }
    property RequestId: string read FRequestId;
    property Retryable: Boolean read FRetryable;
  end;

  { Form fields in the order they were added. A record with two arrays and
    no heap object, so it needs no Free. }
  TStripeParams = record
  private
    FKeys: array of string;
    FValues: array of string;
  public
    procedure Add(const Key, Value: string); overload;
    procedure Add(const Key: string; Value: Int64); overload;
    procedure AddBool(const Key: string; Value: Boolean);
    { Every field of Other, after these. }
    procedure Append(const Other: TStripeParams);
    function Count: Integer;
    function Value(const Key: string): string;
    { key=value&key=value, both sides percent-encoded. Stripe reads
      line_items%5B0%5D%5Bprice%5D as line_items[0][price]. }
    function Encode: string;
  end;

  TStripeReply = record
    Status: Integer;
    Body: string;
    { The Stripe-Should-Retry header: 'true', 'false' or ''. }
    ShouldRetry: string;
    RequestId: string;
  end;

  { The HTTP layer, behind an abstract class for the same reason as in
    Askr.Mail.Resend: the shape of a request cannot be checked otherwise
    without sending it to Stripe. }
  TStripeHttp = class
  public
    function Send(const Method, Url, Secret, IdempotencyKey,
      Form: string): TStripeReply; virtual; abstract;
  end;

  TRealStripeHttp = class(TStripeHttp)
  private
    FTimeoutMs: Integer;
  public
    constructor Create(ATimeoutMs: Integer = DefaultStripeTimeoutMs);
    function Send(const Method, Url, Secret, IdempotencyKey,
      Form: string): TStripeReply; override;
  end;

  TStripeSent = record
    Method: string;
    Url: string;
    Secret: string;
    IdempotencyKey: string;
    Form: string;
  end;

  { Answers with what has been queued, and keeps what it was asked.
    BeforeReply runs before each answer: a test puts the other side of a
    race there. }
  TFakeStripeHttp = class(TStripeHttp)
  private
    FReplies: array of TStripeReply;
    FNext: Integer;
    FSent: array of TStripeSent;
    FBeforeReply: TProcedure;
  public
    property BeforeReply: TProcedure read FBeforeReply write FBeforeReply;
    procedure Queue(const Body: string; Status: Integer = 200;
      const ShouldRetry: string = '');
    function Send(const Method, Url, Secret, IdempotencyKey,
      Form: string): TStripeReply; override;
    function SentCount: Integer;
    function Sent(Index: Integer): TStripeSent;
    function Last: TStripeSent;
  end;

  TStripeClient = class
  private
    FSecret: string;
    FBaseUrl: string;
    FHttp: TStripeHttp;
    FOwnsHttp: Boolean;
    FLastRequestId: string;
    function Call(const Method, Path, IdempotencyKey,
      Form: string): string;
  public
    { An empty base url means api.stripe.com. stripe-mock, in tests, is
      http://localhost:12111. }
    constructor Create(const ASecret: string; const ABaseUrl: string = '');
    destructor Destroy; override;

    { Each returns the reply's JSON, or raises EStripeError. }
    function Post(const Path: string; const P: TStripeParams;
      const IdempotencyKey: string = ''): string;
    function Get(const Path: string): string;
    function Delete(const Path: string): string;

    procedure UseHttp(H: TStripeHttp; Owns: Boolean = True);
    { Never the secret: safe to paste into a bug report. }
    function Describe: string;

    property BaseUrl: string read FBaseUrl;
    property LastRequestId: string read FLastRequestId;
  end;

{ Stripe's error JSON as an EStripeError. Exposed for the tests. }
function StripeErrorFrom(const R: TStripeReply): EStripeError;

{ A string field of a JSON object, '' when it is missing or not a string.
  The replies are read one field at a time, and this is that field. }
function StripeField(const Json, Key: string): string;

implementation

constructor EStripeError.Create(AStatus: Integer; const AType, ACode,
  AParam, ADeclineCode, ARequestId, AMessage: string; ARetryable: Boolean);
begin
  inherited Create(AMessage);
  FStatus := AStatus;
  FType := AType;
  FCode := ACode;
  FParam := AParam;
  FDeclineCode := ADeclineCode;
  FRequestId := ARequestId;
  FRetryable := ARetryable;
end;

{ ------------------------------------------------------------- params -- }

procedure TStripeParams.Add(const Key, Value: string);
begin
  SetLength(FKeys, Length(FKeys) + 1);
  SetLength(FValues, Length(FValues) + 1);
  FKeys[High(FKeys)] := Key;
  FValues[High(FValues)] := Value;
end;

procedure TStripeParams.Add(const Key: string; Value: Int64);
begin
  Add(Key, IntToStr(Value));
end;

procedure TStripeParams.AddBool(const Key: string; Value: Boolean);
begin
  if Value then
    Add(Key, 'true')
  else
    Add(Key, 'false');
end;

procedure TStripeParams.Append(const Other: TStripeParams);
var
  I: Integer;
begin
  for I := 0 to High(Other.FKeys) do
    Add(Other.FKeys[I], Other.FValues[I]);
end;

function TStripeParams.Count: Integer;
begin
  Result := Length(FKeys);
end;

function TStripeParams.Value(const Key: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(FKeys) do
    if FKeys[I] = Key then
      Exit(FValues[I]);
end;

function TStripeParams.Encode: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(FKeys) do
  begin
    if I > 0 then
      Result := Result + '&';
    Result := Result + UrlEncodeValue(FKeys[I]) + '=' +
      UrlEncodeValue(FValues[I]);
  end;
end;

{ --------------------------------------------------------------- HTTP -- }

constructor TRealStripeHttp.Create(ATimeoutMs: Integer);
begin
  inherited Create;
  FTimeoutMs := ATimeoutMs;
end;

function TRealStripeHttp.Send(const Method, Url, Secret, IdempotencyKey,
  Form: string): TStripeReply;
var
  C: THttpClient;
  R: THttpResponse;
begin
  C := THttpClient.Create;
  try
    C.ConnectTimeoutMs := FTimeoutMs;
    C.ReadTimeoutMs := FTimeoutMs;
    { A redirect from Stripe's API is not something to follow with the
      secret attached. }
    C.MaxRedirects := 0;
    C.WithBearer(Secret);
    C.WithHeader('Stripe-Version', StripeApiVersion);
    if IdempotencyKey <> '' then
      C.WithHeader('Idempotency-Key', IdempotencyKey);
    try
      if Method = 'POST' then
        R := C.Post(Url, Form, 'application/x-www-form-urlencoded')
      else
        R := C.Request(Method, Url, '', '');
    except
      on E: EHttpClientError do
        { Retryable: the request may never have arrived, and the key makes
          sending it again safe if it did. }
        raise EStripeError.Create(0, 'network', '', '', '', '',
          'Stripe could not be reached: ' + E.Message, True);
    end;
    Result.Status := R.Status;
    Result.Body := R.Body;
    Result.ShouldRetry := LowerCase(R.Header('Stripe-Should-Retry'));
    Result.RequestId := R.Header('Request-Id');
  finally
    C.Free;
  end;
end;

procedure TFakeStripeHttp.Queue(const Body: string; Status: Integer;
  const ShouldRetry: string);
begin
  SetLength(FReplies, Length(FReplies) + 1);
  FReplies[High(FReplies)].Status := Status;
  FReplies[High(FReplies)].Body := Body;
  FReplies[High(FReplies)].ShouldRetry := ShouldRetry;
  FReplies[High(FReplies)].RequestId := 'req_fake_' + IntToStr(Length(FReplies));
end;

function TFakeStripeHttp.Send(const Method, Url, Secret, IdempotencyKey,
  Form: string): TStripeReply;
begin
  SetLength(FSent, Length(FSent) + 1);
  FSent[High(FSent)].Method := Method;
  FSent[High(FSent)].Url := Url;
  FSent[High(FSent)].Secret := Secret;
  FSent[High(FSent)].IdempotencyKey := IdempotencyKey;
  FSent[High(FSent)].Form := Form;
  if Assigned(FBeforeReply) then
    FBeforeReply();
  if FNext > High(FReplies) then
    raise EStripeError.Create(0, 'fake', '', '', '', '',
      'The fake Stripe has no more queued replies.', False);
  Result := FReplies[FNext];
  Inc(FNext);
end;

function TFakeStripeHttp.SentCount: Integer;
begin
  Result := Length(FSent);
end;

function TFakeStripeHttp.Sent(Index: Integer): TStripeSent;
begin
  Result := FSent[Index];
end;

function TFakeStripeHttp.Last: TStripeSent;
begin
  Result := FSent[High(FSent)];
end;

{ ------------------------------------------------------------- errors -- }

function StripeErrorFrom(const R: TStripeReply): EStripeError;
var
  A: TArena;
  Root, Err: PJsonValue;
  ErrPos: SizeInt;
  Type_, Code, Param, Decline, Msg: string;
  Retry: Boolean;
begin
  Type_ := '';
  Code := '';
  Param := '';
  Decline := '';
  Msg := '';
  A := TArena.Create(16 * 1024);
  try
    if JsonParse(A, Str(R.Body), Root, ErrPos) then
    begin
      Err := JsonMember(Root, 'error');
      if Err <> nil then
      begin
        Type_ := JsonAsString(JsonMember(Err, 'type'));
        Code := JsonAsString(JsonMember(Err, 'code'));
        Param := JsonAsString(JsonMember(Err, 'param'));
        Decline := JsonAsString(JsonMember(Err, 'decline_code'));
        Msg := JsonAsString(JsonMember(Err, 'message'));
      end;
    end;
  finally
    A.Free;
  end;
  { A reply that is not Stripe's JSON -- a proxy's error page -- still
    comes through with its status. The body is not quoted: it is somebody
    else's HTML, and it could be long. }
  if Msg = '' then
    Msg := 'Stripe answered ' + IntToStr(R.Status) + ' without an error message';
  if Type_ <> '' then
    Msg := Msg + ' (' + Type_;
  if Code <> '' then
    Msg := Msg + ', ' + Code;
  if Type_ <> '' then
    Msg := Msg + ')';

  if R.ShouldRetry = 'true' then
    Retry := True
  else if R.ShouldRetry = 'false' then
    Retry := False
  else
    Retry := (R.Status = 409) or (R.Status = 429) or (R.Status >= 500);
  Result := EStripeError.Create(R.Status, Type_, Code, Param, Decline,
    R.RequestId, Msg, Retry);
end;

function StripeField(const Json, Key: string): string;
var
  A: TArena;
  Root: PJsonValue;
  ErrPos: SizeInt;
begin
  Result := '';
  A := TArena.Create(Length(Json) * 2 + 4096);
  try
    if JsonParse(A, Str(Json), Root, ErrPos) then
      Result := JsonAsString(JsonMember(Root, Key));
  finally
    A.Free;
  end;
end;

{ ------------------------------------------------------------- client -- }

constructor TStripeClient.Create(const ASecret, ABaseUrl: string);
begin
  inherited Create;
  FSecret := ASecret;
  FBaseUrl := ABaseUrl;
  if FBaseUrl = '' then
    FBaseUrl := DefaultStripeBaseUrl;
  while (FBaseUrl <> '') and (FBaseUrl[Length(FBaseUrl)] = '/') do
    SetLength(FBaseUrl, Length(FBaseUrl) - 1);
  FHttp := TRealStripeHttp.Create;
  FOwnsHttp := True;
end;

destructor TStripeClient.Destroy;
begin
  if FOwnsHttp then
    FHttp.Free;
  inherited Destroy;
end;

procedure TStripeClient.UseHttp(H: TStripeHttp; Owns: Boolean);
begin
  if FOwnsHttp then
    FHttp.Free;
  FHttp := H;
  FOwnsHttp := Owns;
end;

function TStripeClient.Describe: string;
begin
  Result := 'stripe (' + FBaseUrl + ', ' + StripeApiVersion + ')';
end;

function TStripeClient.Call(const Method, Path, IdempotencyKey,
  Form: string): string;
var
  R: TStripeReply;
begin
  if FSecret = '' then
    raise EStripeError.Create(0, 'config', '', '', '', '',
      'No Stripe secret key. Set STRIPE_SECRET in the environment or in ' +
      '.env: sk_test_... from the dashboard, under Developers > API keys.',
      False);
  R := FHttp.Send(Method, FBaseUrl + Path, FSecret, IdempotencyKey, Form);
  FLastRequestId := R.RequestId;
  if (R.Status < 200) or (R.Status > 299) then
    raise StripeErrorFrom(R);
  Result := R.Body;
end;

function TStripeClient.Post(const Path: string; const P: TStripeParams;
  const IdempotencyKey: string): string;
var
  Key: string;
begin
  Key := IdempotencyKey;
  if Key = '' then
    Key := 'askr-' + RandomHex(16);
  Result := Call('POST', Path, Key, P.Encode);
end;

function TStripeClient.Get(const Path: string): string;
begin
  Result := Call('GET', Path, '', '');
end;

function TStripeClient.Delete(const Path: string): string;
begin
  Result := Call('DELETE', Path, '', '');
end;

end.
