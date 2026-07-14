# codex-lens

Shared, validated domain models for a plan-and-approve engineering workflow. This repository currently contains the shared domain layer only — there is no Mac gateway, OpenAI/Codex integration, iPhone app, or networking of any kind yet.

## Repo layout

This is an npm-workspaces monorepo. All domain code lives in a single workspace package:

```
.
├── package.json          # workspace root: typecheck / lint / test / verify scripts
├── tsconfig.json
├── eslint.config.js
└── packages/
    └── shared/           # @codex-lens/shared — the domain layer
        └── src/
            ├── engineering-plan.ts    # Engineering Plan model + lifecycle
            ├── execution-plan.ts      # Execution Plan model + lifecycle
            ├── approval-contract.ts   # Approval Contract model + lifecycle
            ├── authorization.ts       # gate: Approved approval → Execution Plan
            ├── digest.ts              # SHA-256 content digests
            ├── result.ts              # Result<T> / DomainError helpers
            └── index.ts               # public API surface (barrel export)
```

Every model is built with Zod schemas, constructed through factory functions that return a `Result<T>` (never throw), and frozen for immutability. Serialized records carry a SHA-256 `contentDigest` that is re-verified on parse so tampered or stale content is rejected.

## Domain models

### Engineering Plan

An Engineering Plan captures the human-authored intent for a piece of work: project and feature names, objective, background, requirements, constraints, acceptance criteria, assumptions, and risks. Its content fields are hashed into a `contentDigest` so any drift between an approval and the plan it approved is detectable. The plan moves through a strictly linear lifecycle — `Draft → ReadyForApproval → Approved → SentToCodex → Completed` — and `transitionEngineeringPlan` rejects any transition that skips a step or moves backward.

### Execution Plan

An Execution Plan is the concrete, machine-oriented counterpart to an approved Engineering Plan: the files to modify/create/delete, implementation steps, expected commands, risk and complexity estimates (`Low`/`Medium`/`High`), an estimated duration, and a rollback strategy. Each plan links back to its Engineering Plan via `engineeringPlanId` and carries its own content digest. Its execution lifecycle is a state machine — `Pending → Ready → Running`, with `Running` branching to `Blocked` (which can return to `Ready`), `Complete`, or `Failed`; `Complete` and `Failed` are terminal.

### Approval Contract

An Approval Contract records a human decision about a specific target: who approved, when, why (notes), and exactly what was approved — the target's type (`EngineeringPlan` or `ExecutionPlan`), id, version, and content digest. Pinning the version and digest means an approval is only valid for the exact content that was reviewed. Its lifecycle starts at `Pending` and resolves once, to `Approved`, `Rejected`, or `Cancelled` — all terminal, so an approval can never be reused or reversed.

These models meet at the authorization gate (`authorization.ts`): `createExecutionPlanFromApproval` will only mint an Execution Plan from an Approval Contract that is `Approved`, targets the right Engineering Plan, and matches its current version and content digest.

## Verify

Requires Node >= 26.

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
