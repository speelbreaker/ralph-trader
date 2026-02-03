# Vendor API: Deribit (Execution + Market Data)

Purpose
- Single local source of truth for Deribit integration behavior.
- Reduce guesswork by forcing retrieval from official docs.

Last verified: 2026-02-03

---

## 0) Scope and policy

House policy:
- If exchange state is uncertain (no ack, WS gap, timeout), DO NOT resubmit blindly.
  Enter RECONCILING and resolve truth via exchange queries.

Notes:
- Facts labeled "Docs" are derived from Deribit official documentation.
- Items labeled "House policy" are internal rules layered on top of Deribit behavior.

---

## 1) Environments (Docs + policy)

Docs:
- Deribit provides separate production and test environments.

House policy:
- Default all examples and non-live runs to the test environment.
- Verify API base URLs in the official API docs before live use.

---

## 2) Interfaces (House policy)

Preferred order:
1) JSON-RPC over WebSocket (primary for trading + subscriptions)
2) JSON-RPC over HTTP (low-rate, non-latency critical)
3) FIX (only if explicitly implemented)

---

## 3) Authentication and scopes (Docs)

- `public/auth` is the primary authentication method.
- If no scope is specified, Deribit defaults to connection scope.
- Connection scope tokens are valid only for that connection; when the connection closes, tokens become invalid.
- Session scope is requested via `session:name` and allows token reuse across connections until the session expires.

Implementation requirements (House policy):
- Store token info per connection (or per session if using session scope).
- On reconnect, re-authenticate before subscribing to private channels (unless session scope is used).

---

## 4) Connections, sessions, and limits (Docs)

Limits:
- Max connections per IP: 32 (HTTP + WebSocket count toward the limit).
- Max active sessions per API key or username/password: 16.
- Attempts to open the 33rd connection are rejected with HTTP 429.
- The Deribit web UI uses 2 active connections per user session.

House policy:
- Keep connections minimal and stable.
- Separate sockets by responsibility when needed:
  - Socket A: private order management + private subscriptions
  - Socket B: heavy market data subscriptions

---

## 5) Rate limits and abuse policies (Docs)

- Deribit uses a credit-based rate limiting system.
- Rate limits are applied per sub-account.
- If credits reach zero, requests fail with `too_many_requests` (code 10028) and the session is terminated.
- Web UI usage consumes API credits.
- OTV and API usage policies apply to all traffic and may trigger throttling or disconnects.

House policy:
- Track throttling signals and back off on 10028 or disconnects.
- If repeated 10028 events occur, set RISK_STATE to THROTTLED or HALTED.

---

## 6) Instrument discovery limits (Docs + policy)

Docs:
- `public/get_instruments` has custom rate limits (different from default API methods).

House policy:
- Cache instruments and refresh on a schedule (not per decision tick).
- Prefer WebSocket subscriptions for instrument state when available.

---

## 7) WebSocket subscriptions and reconnects (Docs)

- For order book channels, use `change_id` and `prev_change_id` to detect gaps.
- On reconnect:
  - Re-authenticate for private channels.
  - Re-subscribe to all required channels.
  - For order book channels, the first notification is a full snapshot.
  - For other channels, assume updates were missed and reconcile via snapshots.

House policy:
- Maintain a subscription manager that can replay desired subscriptions after reconnect.
- Never block the WS message loop with slow logic.

---

## 8) Historical orders/trades (Docs)

- Recent orders are available for ~30 minutes without `historical=true`.
- Recent trades are available for ~24 hours without `historical=true`.
- Older records require `historical=true` on supported endpoints.

House policy:
- Use historical endpoints for reconciliation/backfills once recent windows expire.

---

## 9) Idempotency and unknown-ack handling (House policy)

- Every internal intent MUST map to a stable idempotency key.
- Attach a stable client identifier (label/client_order_id pattern) if supported.
- If submit times out or lacks an ack:
  - Enter RECONCILING.
  - Query order state by client identifier.
  - Resubmit only if you can prove the order does not exist.

---

## 10) Implementation guardrails (House policy)

When modifying Deribit integration code, consult:
- This file.
- `specs/CONTRACT.md` and `specs/invariants/GLOBAL_INVARIANTS.md` for safety rules.

In review summaries, list which sections were referenced.

---

## Appendix A) Endpoints referenced by our specs (Internal)

These endpoints are cited in local specs/implementation plans. Treat this list as
"what we currently depend on" rather than a full Deribit API reference.

Public (JSON-RPC):
- `/public/get_instruments` (instrument metadata for tick/step/min/contract multiplier).
- `/public/get_announcements` (maintenance/health polling).

Private (JSON-RPC):
- `/private/buy` and `/private/sell` (order placement).
- `/private/get_account_summary` (limits + fee tier data).

Private WS channels (subscriptions):
- `user.orders.*`
- `user.trades.*`
- `user.portfolio.*`
- `user.changes.*`

Order book consistency:
- `change_id` / `prev_change_id` for gap detection (book incremental streams).

Source references:
- `specs/CONTRACT.md`
- `specs/IMPLEMENTATION_PLAN.md`

---

## Sources (official docs)

- https://docs.deribit.com/api-reference/authentication/public-auth
- https://docs.deribit.com/articles/connection-management-best-practices
- https://docs.deribit.com/articles/access-scope
- https://docs.deribit.com/articles/notifications
- https://support.deribit.com/hc/en-us/articles/26978847197597-Logging-in-to-your-Deribit-Account
- https://support.deribit.com/hc/en-us/articles/25944617523357-Rate-Limits
- https://support.deribit.com/hc/en-us/articles/25973087226909-Accessing-historical-trades-and-orders-using-API
