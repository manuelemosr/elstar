# Changelog

All notable changes to Elstar are documented here. This project adheres to
[Semantic Versioning](https://semver.org/).

## 1.0.0

Initial release ("Elstar bring-up").

- Bounded plan-act-verify loop: model-agnostic plans, goal verification, and
  prompt budgets (`AppleAgentHarness`).
- Device tool catalog: current time, reminder/calendar reads, places
  search/current/directions, weather, and validated public web fetch.
- One-shot "Allow once" confirmations for the single mutation (opening Maps
  directions), with no persistent grants.
- Durable action-receipt journal with confirmed / uncertain / failed outcomes,
  so a possibly-committed write is never silently replayed.
- Host seams for planning, dispatching, event streams, active-operation
  tracking, and DEBUG diagnostics.
- Real Apple-framework services (EventKit, MapKit, CoreLocation, WeatherKit)
  with honest unavailable stubs on unsupported platforms.
- MIT license.
