# Grok Live Usage Design

## Goal

Add the Grok account stored under `~/.grok` to the cmux AI Usage Sidebar and
show its live subscription usage alongside Claude Code, Codex, and
Antigravity.

## Source of truth

Grok stores its interactive OAuth credential in `~/.grok/auth.json`. The file
is a JSON object keyed by issuer and client ID; each value contains the access
token in `key`, the refresh token, expiry, account email, issuer, and public
OIDC client ID.

The installed Grok client obtains its live billing state from:

```text
GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
Authorization: Bearer <access token>
```

The response's `config` object contains `creditUsagePercent`, `currentPeriod`,
and product-level usage. The sidebar will initially render the aggregate
`creditUsagePercent`, because that is the subscription limit that corresponds
to the existing provider bars. `currentPeriod.start` and `.end` define the
window and reset time; the observed account reports a weekly period.

## Architecture

Add `grok` to the shared `UsageProvider` enum and add an optional `grokHome`
field to `AccountConfig`. Discovery will scan direct home-directory children
whose names begin with `.grok` and contain `auth.json`, matching the existing
multi-profile Codex convention. The default account is written as
`"grokHome": "~/.grok"`.

`GrokClient` will read and parse the credential without logging its token. It
will refresh an expired access token through the credential's OIDC issuer and
client ID, using the refresh-token grant at
`https://auth.x.ai/oauth2/token`. Because xAI rotates refresh tokens, a
successful refresh is written atomically into the same issuer entry in
Grok-owned `auth.json`, preserving unrelated fields and owner-only permissions.
A 401 from the billing endpoint gets one refresh-and-retry attempt so
clock skew and server-side invalidation recover without user action.

The billing response becomes one `UsageWindow`: the label is derived from the
period start and end, `creditUsagePercent / 100` becomes `usedFraction`, and
the period end becomes `resetsAt`. `subscription_tier` is not present in the
billing response, so the provider will omit the plan unless the API adds one;
the local credential email will populate the existing detail view.

## Errors and safety

A missing `auth.json`, missing access and refresh credentials, or an empty
credential set is `FetchError.noCredential` and therefore renders as signed
out. Invalid JSON, an unexpected billing payload, failed refresh, and HTTP
errors use the existing red error state. Error messages must never include
access or refresh tokens.

The daemon remains the only component that reads credentials. The sandboxed
sidebar extension receives only the normalized usage snapshot over loopback.

## Testing

Tests will cover stable discovery and tilde paths, credential parsing without
depending on a real token, conversion of weekly billing JSON into the shared
window model, percentage normalization, reset parsing, and the shared wire
round trip with a Grok account. Network behavior will be isolated behind
request construction and payload-conversion helpers so unit tests do not call
the private endpoint.

The implementation will then run the focused Swift tests, the full Swift test
suite, model synchronization, and a build. A live `--once` check may be used
only as a final smoke test and must not print credential material.
