{ The four tables. Times Stripe gives are Stripe's unix seconds, in the
  columns named as Stripe names them; 0 from Stripe is NULL here. }
unit Askr.Plugin.Stripe.CreateTables;

{$mode Delphi}{$H+}

interface

implementation

uses
  Askr.Norn.Schema, Askr.Norn.Migration;

type
  TCreateStripeTables = class(TMigration)
  public
    class function Version: string; override;
    procedure Up(S: TSchemaBuilder); override;
    procedure Down(S: TSchemaBuilder); override;
  end;

class function TCreateStripeTables.Version: string;
begin
  Result := 'stripe:20261001000000';
end;

procedure TCreateStripeTables.Up(S: TSchemaBuilder);
begin
  with S.Create('stripe_customers') do
  begin
    Id;
    { Text, because the framework does not own the user model: the id
      Login takes. }
    Text('user_id', 191).Unique;
    Text('stripe_id', 255).Unique;
    BigInt('created_at');
  end;

  with S.Create('stripe_subscriptions') do
  begin
    Id;
    Text('stripe_id', 255).Unique;
    Text('user_id', 191);
    Text('customer', 255);
    Text('status', 32);
    Text('price', 255).Nullable;
    Int('quantity').Nullable;
    BigInt('trial_end').Nullable;
    BigInt('current_period_end').Nullable;
    BigInt('cancel_at').Nullable;
    BigInt('ended_at').Nullable;
    Bool('cancel_at_period_end').Default(False);
    { The Stripe time of what the row last applied. An older event does
      not overwrite it. }
    BigInt('synced_at');
    Index(['user_id']);
  end;

  with S.Create('stripe_subscription_items') do
  begin
    Id;
    Text('stripe_id', 255).Unique;
    Text('subscription', 255);
    Text('price', 255);
    Int('quantity');
    Index(['subscription']);
  end;

  with S.Create('stripe_events') do
  begin
    Id;
    { The unique index is what makes a second delivery change nothing. }
    Text('stripe_id', 255).Unique;
    Text('type', 100);
    BigInt('created');
    BigInt('received_at');
  end;
end;

procedure TCreateStripeTables.Down(S: TSchemaBuilder);
begin
  S.Drop('stripe_events');
  S.Drop('stripe_subscription_items');
  S.Drop('stripe_subscriptions');
  S.Drop('stripe_customers');
end;

initialization
  RegisterMigration(TCreateStripeTables);

end.
