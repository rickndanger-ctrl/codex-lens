# @codex-lens/gateway

Local HTTP gateway for Codex Lens, built on Fastify.

## Configuration

| Environment variable | Required | Description |
| --- | --- | --- |
| `CODEX_LENS_GATEWAY_TOKEN` | yes | Secret bearer token required on every route except `GET /v1/health`. Clients must send `Authorization: Bearer <token>`. If unset (or empty) at runtime the gateway fails closed and rejects all authenticated requests with 401. Never commit a value; provide it via the environment. |
| `CODEX_LENS_PORT` | no | Listen port (default `8787`). |

## Authentication

Auth is attached via `registerAuth(server)` from `src/auth/index.ts`. The incoming
bearer token is compared against `CODEX_LENS_GATEWAY_TOKEN` using a constant-time
comparison. `GET /v1/health` bypasses auth; every other request without a valid
token receives a `401` with body:

```json
{ "statusCode": 401, "error": "Unauthorized", "message": "..." }
```
