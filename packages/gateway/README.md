# @codex-lens/gateway

Local HTTP gateway for Codex Lens, built on Fastify.

## Local-only posture

The gateway binds exclusively to the loopback interface (`127.0.0.1`) and is
never intended to be exposed beyond the local machine. Its source makes no
external network calls: no `fetch`, no `http`/`https`/`net`/`dgram` clients.
HTTP task execution is handled by a mock runner that writes lifecycle events to
a local SQLite database.

Three modules — and only three — may start a child process: `codex/transport.ts`
(the Codex app-server), `test-runner.ts`, and `sandbox.ts` (which runs git to
snapshot and roll back a throwaway working copy). No HTTP route reaches any of
them.

All three spawn with `shell: false`. `sandbox.ts` and `codex/transport.ts` build
discrete argv arrays rather than concatenated command lines, so each value in
those arrays is delivered to the child verbatim as one argument and is never
parsed as shell syntax. What each module may run is constrained, but the
constraint differs and is worth stating exactly:

- `sandbox.ts` runs the literal `git`, with argv this module builds.
- `codex/transport.ts` runs `CODEX_APP_SERVER_CMD` (default `codex`) with the
  fixed argv `['app-server']`. The executable is operator-configured, so it is
  trusted to the same degree as the environment the gateway runs in; because
  there is no shell, the value must be an executable path rather than a command
  line.
- `test-runner.ts` runs a test command it is handed, which is **not** trusted on
  its face. It splits the received command string on whitespace into an
  executable plus argv, so quoting is **not** preserved: a value containing
  spaces, quotes, or `$(…)` is split into multiple argv tokens, not delivered
  verbatim as one argument. Its safety properties are the allowlist check
  (`assertCommandAllowed`) and the child cwd being pinned to the sandbox root,
  not shell-quote safety. The vertical slice supplies the approved plan's
  `expectedCommands` as that allowlist, so a run can only execute a command the
  reviewer's digest already covered. `runTests` treats an omitted allowlist as
  "the caller already authorized this", so a new caller that passes no list
  gets no command check.

The HTTP mock runner does not call `runTests` or spawn a child process. It
simulates execution and checks each command directly against
`project.allowedCommands` with `assertCommandAllowed`.

No route can commit, push, or deploy. The project registry stores
`allowCommit`/`allowPush`/`allowDeploy` flags for future policy decisions, but
no endpoint acts on them or runs git/deploy commands. This posture is enforced
by `test/securityPosture.test.ts`, which pins the route surface, the loopback
bind, the absence of network imports, and the child-process allowlist above —
adding a fourth spawning module fails that test by design.

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
| `CODEX_APP_SERVER_CMD`     | no       | Codex executable used by the vertical-slice CLI (default `codex`). Launched directly with `app-server` and `shell: false`; shell syntax is not evaluated. See the [M3 vertical slice runbook](#m3-vertical-slice-runbook).                                                             |

## M3 vertical slice runbook

The M3 slice drives one real Codex edit end to end: request → generated
execution plan → approval check → edit → verification, against the registered
sample repository's `src/calculator.js`, inside a disposable sandbox.

### Prerequisites

- **Node 26.x.** The workspace pins `>=26 <27`; check with `node --version`.
- **Dependencies installed** from the repo root: `npm install`.
- **A local Codex CLI that is already authenticated.** The slice inherits the
  ambient Codex auth of the command it launches — normally established once with
  `codex login`. It never reads, prompts for, stores, or logs credentials, and
  there is nothing to configure here beyond having that login already work.
- **No gateway token.** `CODEX_LENS_GATEWAY_TOKEN` is for the HTTP routes; the
  slice CLI does not go through them.

### Run it

From the repo root:

```sh
npm run slice -- "Fix add so it returns the sum of both numbers"
```

Quote the request when it contains spaces. `npm run slice -- --help` lists all
options. Pass `--thread-id <id>` to resume a Codex thread printed by an earlier
run rather than starting a fresh one.

The CLI initializes Codex, confirms authentication, creates or resumes the
thread, runs the orchestrator, prints the real run report as JSON, and then
tries to remove the sandbox — reporting it on stderr and exiting `1` if removal
fails. See the [safety model](#safety-model-registry-allowlist-then-plan-scope-then-sandbox).

Exit codes:

| Code | Meaning                                                                         |
| ---- | ------------------------------------------------------------------------------- |
| `0`  | The edit landed and the plan's own verification command passed.                 |
| `1`  | The slice failed, Codex app-server would not start, or the sandbox outlived it. |
| `2`  | Bad arguments; usage is printed.                                                |
| `3`  | Codex authentication is unavailable — see the fail-stop below.                  |

### Selecting the Codex command

`CODEX_APP_SERVER_CMD` names the executable to launch (default `codex`). It is
spawned directly with the `app-server` argument and `shell: false`, so shell
syntax in the value is not evaluated — set it to a path, not a command line:

```sh
CODEX_APP_SERVER_CMD=/opt/codex/bin/codex npm run slice -- "…"
```

### Safety model: registry allowlist, then plan scope, then sandbox

Edits only ever touch the sample repo, and that is enforced at three
independent layers rather than by convention:

1. **The registry allowlist** (`src/registryConfig.ts`) is a frozen, in-source
   list — there is no way to register a repo at runtime. It holds exactly two
   entries: `sample-project` (the fixture, `editable: true`) and `codex-lens`
   (this repo itself, `editable: false`). `assertEditableTarget` resolves a
   target to its real path and refuses anything that is not inside a registered
   **editable** root — which means this repo is never a legal edit target, and
   `..` traversal out of the fixture is rejected rather than followed.
2. **The approved plan's scope** (`src/plan-scope.ts`) holds Codex's returned
   edits to the exact file lists the approval's digest covered. A path the plan
   never named is refused, and so is a path named for a different purpose —
   writing a `create` file that already exists, or a `modify` file that does
   not, are both changes the reviewer did not approve.
3. **The sandbox** (`src/sandbox.ts`) is where the writing actually happens.
   Codex is handed a throwaway copy of the fixture under a temp dir, never the
   fixture itself, so the registered sample repo is not modified even on the
   success path. The copy is git-backed for diff and rollback; a run whose tests
   fail is rolled back.

   Removal is attempted on every path, but it is not guaranteed — `rm` can fail.
   The slice does not paper over that: a sandbox it could not remove is reported
   rather than silently left behind. When the edit itself succeeded but disposal
   failed, the CLI prints `SANDBOX_DISPOSE_FAILED` and the underlying error to
   stderr and exits `1` rather than `0`, so a leftover copy is never reported as
   a clean run. On the failure path the orchestrator reports
   `SANDBOX_CLEANUP_FAILED`, which names the sandbox's path and carries the
   original failure, the disposal error, and whether the copy reached its
   baseline — so the message distinguishes a leftover copy holding no edit from
   one that may still hold the edit. Either way the path is yours to remove by
   hand.

The fixture at `fixtures/sample-project` is intentionally broken — `add`
subtracts — and its test suite is expected to report one pass and one failure.
That is the bug the slice exists to fix, in a sandbox copy. Because the fixture
must stay broken while the workspace stays green, its test file is deliberately
named `test/calculator.js` rather than `test/calculator.test.js`, which keeps it
out of Vitest's include globs and therefore out of root `npm run verify`. Both
halves of that arrangement are pinned by `test/fixtureIsolation.test.ts`.

### Auth fail-stop

If Codex has no usable authentication, the run stops. The CLI exits `3`, prints
a message pointing at `codex login`, and prints **no run report** — a slice that
cannot reach Codex fails loudly rather than reporting a fabricated or partial
result. Authenticate the configured Codex command and retry.

Do not put credentials in this repository, in the request string, or in these
docs. If a live Codex command needs a credential that is not already available,
stop and request it from the operator's vault using the project secret request
protocol:

```text
NEEDS_SECRET: <ENVIRONMENT_VARIABLE_NAME> — <one-line reason>
```

## Gateway HTTP authentication

This section is about the bearer token on the HTTP routes, which is separate
from the Codex authentication the vertical slice inherits.

Auth is attached via `registerAuth(server)` from `src/auth/index.ts`. The incoming
bearer token is compared against `CODEX_LENS_GATEWAY_TOKEN` using a constant-time
comparison. `GET /v1/health` bypasses auth; every other request without a valid
token receives a `401` with body:

```json
{ "statusCode": 401, "error": "Unauthorized", "message": "..." }
```
