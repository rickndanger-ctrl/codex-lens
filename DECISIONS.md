# Codex Lens Decisions

## Glasses remain the primary product surface

Codex Lens is glasses-first. Conversation input, explicit visual context, and spoken task feedback belong on smart glasses. The phone and local gateway are supporting infrastructure, not the end product.

## Keep a deterministic text protocol demo

The repository exposes `npm run demo` as a text-only vertical slice from conversation through a queued Codex task. It uses fixed conversation and approval inputs and prints only stable lifecycle states, while still exercising the real domain approval gates and gateway task store.

This demo exists for repeatable development, CI, and protocol review without hardware or external services. It does not claim that glasses integration is complete and must not become a parallel text-first product direction.
