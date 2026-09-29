# Contributing to Elstar

Thanks for helping improve Elstar. This project is a reusable, host-agnostic
device-tool harness, so changes should keep the library generic: no app
branding, no UI, no model runtime, and no network policy baked in.

## Development setup

- macOS with Xcode 16+ installed (the package targets swift-tools 6.0, iOS 18
  and macOS 14).
- If your active toolchain is the Command Line Tools, point Swift at Xcode so
  the Swift Testing macro plugin resolves:

  ```bash
  swift build
  swift test

  # or, when CLT is selected:
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  ```

## What to work on

- Bug fixes and correctness/reliability fixes are always welcome.
- New tool operations: add the case/request to `AppleToolDomain.swift`, a
  service protocol in `AppleToolServices.swift`, an implementation in
  `AppleNativeToolServices.swift`, an executor arm in
  `AppleToolCoordinator.swift`, and the planner description in
  `DeviceAgentPlannerSupport.swift`.
- Keep public API additive where possible; if you remove or rename a public
  type, call it out in the PR description and update `CHANGELOG.md`.

## Pull requests

- Keep changes focused and explain the behavior change and how you verified
  it.
- Add or update tests under `Tests/ElstarTests/`. Prefer injecting fakes
  (services, clock, HTTP client) over depending on device state.
- Run `swift build` and `swift test` locally and note the result.
- Use ASCII `-` rather than em dashes in user-facing copy.
- Never commit secrets or personal data.

## Scope guardrails

- The model never performs an effect directly; only the harness does, and only
  after a one-shot confirmation for mutations.
- Reads verify by read-back; mutations write a durable receipt.
- Failures are honest - unavailable services throw, they never fake success.

## License

By contributing you agree your contributions are licensed under the MIT
License (see [LICENSE](LICENSE)).
