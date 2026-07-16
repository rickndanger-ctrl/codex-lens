# @codex-lens/gateway

Local HTTP gateway for Codex Lens, built on Fastify.

## Local-only posture

The gateway binds exclusively to the loopback interface (`127.0.0.1`) and is
never intended to be exposed beyond the local machine. Its source makes no
external network calls: no `fetch`, no `http`/`https`/`net`/`dgram` clients,
and no child processes. Task execution is handled by a mock runner that writes
lifecycle events to a local SQLite database.

No route can commit, push, or deploy. The project registry stores
`allowCommit`/`allowPush`/`allowDeploy` flags for future policy decisions, but
no endpoint acts on them or runs git/deploy commands. This posture is enforced
by `test/securityPosture.test.ts`, which pins the route surface, the loopback
bind, and the absence of network/shell imports.

## Endpoints

All endpoints exchange JSON. Every route except `GET /v1/health` requires
`Authorization: Bearer <CODEX_LENS_GATEWAY_TOKEN>`.

| Method | Path                       | Auth | Description                                                                                                                                                                                                                  |
| ------ | -------------------------- | ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET`  | `/`                        | yes  | Gateway identity: `{ "name": "@codex-lens/gateway", "status": "ok" }`.                                                                                                                                                       |
| `GET`  | `/v1/health`               | no   | Liveness probe: `{ "status": "ok", "version": "<gateway version>" }`.                                                                                                                                                        |
| `GET`  | `/v1/projects`             | yes  | Lists registered projects from the local registry: `{ "projects": [...] }`.                                                                                                                                                  |
| `POST` | `/v1/tasks`                | yes  | Creates a task. Body: `{ "projectId", "idempotencyKey", "requestedPath"? }`. The requested path must resolve inside the project root. Returns the task record; replays of the same idempotency key return the existing task. |
| `GET`  | `/v1/tasks/:taskId`        | yes  | Returns a task record by id, or 404.                                                                                                                                                                                         |
| `GET`  | `/v1/tasks/:taskId/events` | yes  | Returns the task's normalized lifecycle events: `{ "events": [...] }`.                                                                                                                                                       |

## Configuration

| Environment variable       | Required | Description                                                                                                                                                                                                                                                                            |
| -------------------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CODEX_LENS_GATEWAY_TOKEN` | yes      | Secret bearer token required on every route except `GET /v1/health`. Clients must send `Authorization: Bearer <token>`. If unset (or empty) at runtime the gateway fails closed and rejects all authenticated requests with 401. Never commit a value; provide it via the environment. |
| `CODEX_LENS_PORT`          | no       | Listen port (default `8787`).                                                                                                                                                                                                                                                          |
| `CODEX_APP_SERVER_CMD`     | no       | Codex executable used by the live vertical-slice CLI (default `codex`). The command is launched directly with `app-server`; shell syntax is not evaluated.                                                                                                                             |

## Live sample vertical slice

Run a real Codex edit against the registered sample repository's
`src/calculator.js` inside a disposable sandbox:

```sh
npm run slice -- "Fix add so it returns the sum of both numbers"
```

Use `npm run slice -- --help` for all options. Pass `--thread-id <id>` to
resume a Codex thread printed by an earlier run. The CLI initializes Codex,
checks authentication, creates or resumes the thread, runs the orchestrator,
prints the real report, and removes the sandbox. It never edits the registered
fixture directly.

The CLI uses `CODEX_APP_SERVER_CMD` out of band and inherits that process's
Codex authentication. Do not put credentials in this repository or in the
request string. If a live Codex command needs a credential that is not already
available, stop and request it from the operator's vault using the project
secret request protocol:

```text
NEEDS_SECRET: <ENVIRONMENT_VARIABLE_NAME> — <one-line reason>
```

An authentication-unavailable response exits non-zero and prints no run
report. Authenticate the configured Codex command (normally with
`codex login`) before retrying.

## Authentication

Auth is attached via `registerAuth(server)` from `src/auth/index.ts`. The incoming
bearer token is compared against `CODEX_LENS_GATEWAY_TOKEN` using a constant-time
comparison. `GET /v1/health` bypasses auth; every other request without a valid
token receives a `401` with body:

```json
{ "statusCode": 401, "error": "Unauthorized", "message": "..." }
```
