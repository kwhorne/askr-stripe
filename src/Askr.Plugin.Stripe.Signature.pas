{ Askr.Plugin.Stripe.Signature -- the Stripe-Signature header.

  Stripe signs t.payload -- the timestamp, a dot, and the raw body as it
  arrived -- with HMAC-SHA256 under the endpoint's secret, whsec_ prefix
  and all, and sends

      Stripe-Signature: t=1700000000,v1=<hex>,v1=<hex>

  There can be several v1 values while a secret is being rolled, and a v0
  that is not a signature anyone should accept. One v1 that matches is
  enough.

  The rules are stripe-python's, and tests/vectors/signatures.txt holds
  this to it: tools/signatures.py asks stripe-python for its verdict on
  each case, and the suite requires the same. That includes two choices
  that are Stripe's rather than obvious:

  * A timestamp in the future is accepted. Only one older than the
    tolerance is refused: a replay is old by definition, and a server
    whose clock is behind Stripe's should not refuse every event.
  * A tolerance of 0 turns the time check off. The webhook route never
    passes 0.

  The body must be the bytes as they arrived. A body parsed and written
  back out as JSON is a different string, and no signature matches it. }
unit Askr.Plugin.Stripe.Signature;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Core.Crypto;

const
  DefaultStripeTolerance = 300;

type
  TStripeSignatureCheck = (
    scOk,
    scNoHeader,
    scNoSecret,
    scMalformed,     { no t, or a t that is not a number }
    scNoSignature,   { no v1 at all }
    scMismatch,
    scTooOld);

function VerifyStripeSignature(const Payload, Header, Secret: string;
  Tolerance, NowUnix: Int64): TStripeSignatureCheck;

{ The header Stripe would send for Payload at Timestamp. For an app's own
  tests of its webhook listeners. }
function StripeSignatureHeader(const Payload, Secret: string;
  Timestamp: Int64): string;

{ The name the vectors use for a verdict: ok, no_header, ... }
function SignatureCheckName(C: TStripeSignatureCheck): string;

implementation

function Sign(const Payload, Secret: string; Timestamp: Int64): string;
begin
  Result := HmacSha256Hex(Secret, IntToStr(Timestamp) + '.' + Payload);
end;

function StripeSignatureHeader(const Payload, Secret: string;
  Timestamp: Int64): string;
begin
  Result := 't=' + IntToStr(Timestamp) + ',v1=' +
    Sign(Payload, Secret, Timestamp);
end;

function VerifyStripeSignature(const Payload, Header, Secret: string;
  Tolerance, NowUnix: Int64): TStripeSignatureCheck;
var
  Items: TStringArray;
  I, Eq: Integer;
  Key, Value, Expected: string;
  HaveT, AnyV1, Matched: Boolean;
  T: Int64;
begin
  if Header = '' then
    Exit(scNoHeader);
  if Secret = '' then
    Exit(scNoSecret);

  HaveT := False;
  AnyV1 := False;
  Matched := False;
  T := 0;
  Items := Header.Split([',']);
  { Two passes, because the timestamp can come after the signatures and
    the expected signature needs it. }
  for I := 0 to High(Items) do
  begin
    Eq := Pos('=', Items[I]);
    if Eq = 0 then
    begin
      { stripe-python splits on '=' and indexes the value only for a key
        it is looking for: a bare t or v1 is malformed, a bare anything
        else is ignored. }
      if (Items[I] = 't') or (Items[I] = 'v1') then
        Exit(scMalformed);
      Continue;
    end;
    Key := Copy(Items[I], 1, Eq - 1);
    if (Key = 't') and not HaveT then
    begin
      Value := Copy(Items[I], Eq + 1, MaxInt);
      if Pos('=', Value) > 0 then
        Value := Copy(Value, 1, Pos('=', Value) - 1);
      if not TryStrToInt64(Value, T) then
        Exit(scMalformed);
      HaveT := True;
    end;
  end;
  if not HaveT then
    Exit(scMalformed);

  Expected := Sign(Payload, Secret, T);
  for I := 0 to High(Items) do
  begin
    Eq := Pos('=', Items[I]);
    if Eq = 0 then
      Continue;
    if Copy(Items[I], 1, Eq - 1) <> 'v1' then
      Continue;
    AnyV1 := True;
    { The value ends at the next '=', as in stripe-python's split. }
    Value := Copy(Items[I], Eq + 1, MaxInt);
    if Pos('=', Value) > 0 then
      Value := Copy(Value, 1, Pos('=', Value) - 1);
    { Every candidate is compared, in constant time, so how long this
      takes says nothing about how close a guess came. }
    if ConstantTimeEquals(Value, Expected) then
      Matched := True;
  end;
  if not AnyV1 then
    Exit(scNoSignature);
  if not Matched then
    Exit(scMismatch);

  if (Tolerance > 0) and (T < NowUnix - Tolerance) then
    Exit(scTooOld);
  Result := scOk;
end;

function SignatureCheckName(C: TStripeSignatureCheck): string;
begin
  case C of
    scOk: Result := 'ok';
    scNoHeader: Result := 'no_header';
    scNoSecret: Result := 'no_secret';
    scMalformed: Result := 'malformed';
    scNoSignature: Result := 'no_signature';
    scMismatch: Result := 'mismatch';
    scTooOld: Result := 'too_old';
  end;
end;

end.
