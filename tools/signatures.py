"""Writes tests/vectors/signatures.txt: Stripe-Signature cases, each with
stripe-python's own verdict.

The headers are built here, but the verdict is not ours: every case goes
through stripe.WebhookSignature.verify_header with the clock set to the
case's "now", and what it raised -- or that it raised nothing -- is what
the Pascal suite has to agree with.

    python3 -m venv .venv && .venv/bin/pip install stripe
    .venv/bin/python tools/signatures.py > tests/vectors/signatures.txt

One case per line, tab separated:

    name  payload-as-hex  header  secret  now  tolerance  verdict
"""

import hashlib
import hmac
import sys
import time
from unittest import mock

import stripe
from stripe import WebhookSignature
from stripe._error import SignatureVerificationError

SECRET = "whsec_test_4eC39HqLyjWDarjtT1zdp7dc"
OTHER = "whsec_test_other_secret_nobody_uses"

EVENT = (
    '{\n  "id": "evt_1QpvTest",\n  "object": "event",\n'
    '  "api_version": "2026-08-26.dahlia",\n  "created": 1767225600,\n'
    '  "data": {"object": {"id": "sub_1", "object": "subscription"}},\n'
    '  "type": "customer.subscription.updated"\n}'
)
UNICODE = '{"id":"evt_2","object":"event","data":{"object":{"name":"Blåbærsyltetøy 🫐"}}}'
T = 1767225600


def sig(payload, secret, t):
    signed = f"{t}.{payload}".encode("utf-8")
    return hmac.new(secret.encode("utf-8"), signed, hashlib.sha256).hexdigest()


def verdict(payload, header, secret, now, tolerance):
    with mock.patch.object(time, "time", return_value=now):
        try:
            WebhookSignature.verify_header(payload, header, secret, tolerance)
            return "ok"
        except SignatureVerificationError as e:
            m = str(e)
    for prefix, name in [
        ("No Stripe-Signature header", "no_header"),
        ("No webhook secret", "no_secret"),
        ("Unable to extract", "malformed"),
        ("No signatures found with expected scheme", "no_signature"),
        ("No signatures found matching", "mismatch"),
        ("Timestamp outside the tolerance", "too_old"),
    ]:
        if m.startswith(prefix):
            return name
    raise SystemExit(f"an error this script does not know: {m}")


good = sig(EVENT, SECRET, T)
cases = [
    ("valid", EVENT, f"t={T},v1={good}", SECRET, T + 10, 300),
    ("valid at the edge of the tolerance", EVENT, f"t={T},v1={good}", SECRET, T + 300, 300),
    ("one second past the tolerance", EVENT, f"t={T},v1={good}", SECRET, T + 301, 300),
    ("a day old", EVENT, f"t={T},v1={good}", SECRET, T + 86400, 300),
    ("a day old with the time check off", EVENT, f"t={T},v1={good}", SECRET, T + 86400, 0),
    ("from the future", EVENT, f"t={T},v1={good}", SECRET, T - 3600, 300),
    ("timestamp after the signature", EVENT, f"v1={good},t={T}", SECRET, T, 300),
    ("a second v1 that matches", EVENT, f"t={T},v1={'0' * 64},v1={good}", SECRET, T, 300),
    ("a second v1 that does not", EVENT, f"t={T},v1={good},v1={'f' * 64}", SECRET, T, 300),
    ("only v0", EVENT, f"t={T},v0={good}", SECRET, T, 300),
    ("v0 and a wrong v1", EVENT, f"t={T},v0={good},v1={'a' * 64}", SECRET, T, 300),
    ("the other secret", EVENT, f"t={T},v1={sig(EVENT, OTHER, T)}", SECRET, T, 300),
    ("signed for another timestamp", EVENT, f"t={T + 1},v1={good}", SECRET, T, 300),
    ("one byte of the body changed", EVENT.replace("sub_1", "sub_2"), f"t={T},v1={good}", SECRET, T, 300),
    ("the body with a trailing newline", EVENT + "\n", f"t={T},v1={good}", SECRET, T, 300),
    ("upper case hex", EVENT, f"t={T},v1={good.upper()}", SECRET, T, 300),
    ("a truncated signature", EVENT, f"t={T},v1={good[:63]}", SECRET, T, 300),
    ("no header", EVENT, "", SECRET, T, 300),
    ("no secret", EVENT, f"t={T},v1={good}", "", T, 300),
    ("no timestamp", EVENT, f"v1={good}", SECRET, T, 300),
    ("a timestamp that is not a number", EVENT, f"t=abc,v1={good}", SECRET, T, 300),
    ("a bare t", EVENT, f"t,v1={good}", SECRET, T, 300),
    ("a bare v1", EVENT, f"t={T},v1", SECRET, T, 300),
    ("an empty item", EVENT, f"t={T},,v1={good}", SECRET, T, 300),
    ("an unknown scheme beside v1", EVENT, f"t={T},v9=zz,v1={good}", SECRET, T, 300),
    ("a second t is ignored", EVENT, f"t={T},t={T + 99},v1={good}", SECRET, T, 300),
    ("the value ends at the next equals sign", EVENT, f"t={T},v1={good}=junk", SECRET, T, 300),
    ("unicode in the body", UNICODE, f"t={T},v1={sig(UNICODE, SECRET, T)}", SECRET, T, 300),
    ("an empty body", "", f"t={T},v1={sig('', SECRET, T)}", SECRET, T, 300),
    ("the secret without whsec_", EVENT, f"t={T},v1={sig(EVENT, SECRET[6:], T)}", SECRET, T, 300),
]

print(f"# stripe-python {stripe.VERSION}: WebhookSignature.verify_header's verdicts.")
print("# Written by tools/signatures.py; do not edit by hand.")
for name, payload, header, secret, now, tol in cases:
    v = verdict(payload, header, secret, now, tol)
    print("\t".join([name, payload.encode("utf-8").hex(), header, secret, str(now), str(tol), v]))
