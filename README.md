# codex-lens

Codex Lens is a native iPhone and Ray-Ban Meta interface for a safety-bound Codex workflow. It combines a Realtime voice conversation, explicit glasses still capture with on-device OCR, direct read-only inspection of an approved project by Codex, a tailnet-only Mac gateway, persistent repository tasks, and policy-bound Mac control. Ordinary reversible Mac and UI actions execute directly. Consequential actions stop for exact confirmation of the specific action, target, and content. Siri remains the glasses messaging path. The gateway itself binds to loopback; private remote access is provided by Tailscale Serve.

The physical iPhone app lives at `apps/ios/CodexLensApp/CodexLensApp.xcodeproj`. Current verified device state and remaining acceptance gates are recorded in [docs/BUILD_LOG.md](docs/BUILD_LOG.md).

## Repo layout

This is an npm-workspaces monorepo with two workspace packages:

```
.
├── package.json          # workspace root: typecheck / lint / test / verify / slice scripts
├── tsconfig.json
├── eslint.config.js
└── packages/
    ├── shared/           # @codex-lens/shared — the domain layer
    │   └── src/
    │       ├── engineering-plan.ts    # Engineering Plan model + lifecycle
    │       ├── execution-plan.ts      # Execution Plan model + lifecycle
    │       ├── approval-contract.ts   # Approval Contract model + lifecycle
    │       ├── authorization.ts       # gate: Approved approval → Execution Plan
    │       ├── digest.ts              # SHA-256 content digests
    │       ├── result.ts              # Result<T> / DomainError helpers
    │       └── index.ts               # public API surface (barrel export)
    └── gateway/          # @codex-lens/gateway — local Fastify gateway + Codex slice
        ├── src/
        └── fixtures/sample-project/   # the only allowlisted edit target
```

Every model is built with Zod schemas, constructed through factory functions that return a `Result<T>` (never throw), and frozen for immutability. Serialized Engineering Plans and Execution Plans carry a SHA-256 `contentDigest` that is re-verified on parse so tampered or stale content is rejected; Approval Contracts do not carry a digest of their own — they pin the digest of the target they approve.

## Domain models

### Engineering Plan

An Engineering Plan captures the human-authored intent for a piece of work: project and feature names, objective, background, requirements, constraints, acceptance criteria, assumptions, and risks. Its content fields are hashed into a `contentDigest` so any drift between an approval and the plan it approved is detectable. The plan moves through a strictly linear lifecycle — `Draft → ReadyForApproval → Approved → SentToCodex → Completed` — and `transitionEngineeringPlan` rejects any transition that skips a step or moves backward.

### Execution Plan

An Execution Plan is the concrete, machine-oriented counterpart to an approved Engineering Plan: the files to modify/create/delete, implementation steps, expected commands, risk and complexity estimates (`Low`/`Medium`/`High`), an estimated duration, and a rollback strategy. Each plan links back to its Engineering Plan via `engineeringPlanId` and carries its own content digest. Its execution lifecycle is a state machine — `Pending → Ready → Running`, with `Running` branching to `Blocked` (which can return to `Ready`), `Complete`, or `Failed`; `Complete` and `Failed` are terminal.

### Approval Contract

An Approval Contract records a human decision about a specific target: who approved, when, why (notes), and exactly what was approved — the target's type (`EngineeringPlan` or `ExecutionPlan`), id, version, and content digest. Pinning the version and digest means an approval is only valid for the exact content that was reviewed. Its lifecycle starts at `Pending` and resolves once, to `Approved`, `Rejected`, or `Cancelled` — all terminal states, from which no further transitions are allowed.

These models meet at authorization gates in the shared model and gateway. Every gate checks the target type and id, requires the target's current version, and recomputes its digest from current content instead of trusting the stored digest. `createExecutionPlanFromApproval` only mints an Execution Plan after those checks, and the gateway repeats them immediately before starting a Codex edit.

## Gateway and the M3 vertical slice

`packages/gateway` is a loopback-only Fastify gateway, and it hosts the M3 vertical slice: one real Codex edit driven end to end — request → generated execution plan → approval check → edit → verification — against a deliberately broken sample fixture, inside a disposable sandbox.

The iPhone can also ask the home Mac to inspect the currently selected approved project through `POST /v1/codex/inspect`. That path is read-only, network-disabled, constrained to the gateway allowlist, and returns a verified summary plus relative file paths. It does not authorize edits, commits, pushes, or deployment.

```sh
npm run slice -- "Fix add so it returns the sum of both numbers"
```

**[packages/gateway/README.md](packages/gateway/README.md) is the runbook.** It covers the prerequisites (Node 26.x and an already-authenticated local Codex CLI), the `CODEX_APP_SERVER_CMD` variable, the registry-allowlist / plan-scope / sandbox safety model that keeps edits inside the sample repo, and the fail-stop behavior when Codex auth is unavailable. Read it before running a live slice.

## Verify

Requires Node 26.x.

```sh
npm install
npm run verify   # typecheck + lint + test
```

Or run the steps individually:

```sh
npm run typecheck
npm run lint
npm test
```
