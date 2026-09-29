# Architecture

This document describes how Elstar is put together and how one request
flows through it. For a file map and integration guide, see the
[README](../README.md).

## Layers

```
host app
  |  planner (model)          event sink / tracking / diagnostics
  v                                  ^
AppleAgentHarness  --- plans, budgets, goal verification
  |
  v
AppleToolExecutor (AppleToolDispatching) --- confirmations, receipts, one-at-a-time
  |
  v
AppleToolServices (protocols) --- real EventKit/MapKit/CoreLocation/WeatherKit/URLSession
```

The harness has no opinion about the model. A planner produces plain values
(`AppleAgentPlan`, `AppleAgentStep`); the harness executes and verifies them.
Any model-runtime, transport, or UI concern stays in the host.

## Plan-act-verify

1. **Plan.** `AppleAgentHarness.plan(goals:)` strictly maps planner output to
   `AppleAgentGoal`s. Goal ids are assigned by the harness, never by the
   model, and an actionable plan with no valid goals is `.invalid` - the
   harness refuses to fall back to a permissive "something happened" check.
2. **Act.** `run(task:history:goals:)` asks the planner for each next step
   (bounded by `maxSteps`), then dispatches it through the executor. The
   executor serializes operations, gates mutations behind a one-shot
   confirmation, and records a receipt.
3. **Verify.** A goal is only discharged by a matching, confirmed result
   (`AppleToolStatus.confirmed` with a read-back or a write receipt). A
   failed or declined step does not satisfy its goal. The run ends when all
   goals are satisfied, or with a bounded recovery replan for reads.

## Confirmations and receipts

- Every mutation routes through `AppleConfirmationStore` and asks the person
  for a single **Allow once** decision (`PendingInteraction`). There is no
  persistent grant and no silent retry.
- `AppleToolJournal` durably records each effect as `confirmed`, `failed`,
  or `uncertain`. An `uncertain` outcome is surfaced but never auto-replayed,
  so a possibly-committed write is not repeated after a relaunch.
- `AppleOnceFlag` guards against a single operation firing its effect twice.

## Concurrency

- `AppleOperationSerializer` is an actor that admits one operation at a time
  per executor, so two tool calls cannot interleave device effects.
- `AppleToolJournal` is an actor; receipts are safe to read/write across
  tasks.
- `AppleSingleResumeGuard` protects callbacks that Apple frameworks may fire
  more than once (for example `EKEventStore` fetch completions) from
  double-resuming a continuation and crashing.

## Seams

| seam | direction | purpose |
| --- | --- | --- |
| `AppleAgentPlanner` | host -> harness | plan and next-step decisions; the only model coupling |
| `AppleToolDispatching` | host -> harness | implemented by `AppleToolExecutor`; runs one operation |
| `HarnessToolEventSink` | harness -> host | tool deltas, receipts, permission interactions |
| `HarnessActiveOperationTracking` | harness -> host | which operation is in flight per conversation |
| `HarnessDiagnosticRecording` | harness -> host (DEBUG) | developer diagnostics; off in release |
| `AppleToolServices` | host -> harness | real or unavailable native services |
| `AppleClock` | host -> harness | injectable time for deterministic behavior/tests |

## Safety invariants

- The model never performs an effect directly; only the harness does, and
  only after confirmation for mutations.
- Untrusted web content is treated as evidence, not instructions, and is
  bounded before it reaches a planner.
- Read-back verification is required before a goal is considered complete.
- Failures are honest: unavailable services throw, they do not fake success.
