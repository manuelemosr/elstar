# Changelog

All notable changes to Elstar are documented here. This project adheres to
[Semantic Versioning](https://semver.org/).

## 1.0.0

Initial release ("Elstar bring-up").

- Bounded plan-act-verify loop: model-agnostic plans, goal verification, and
  prompt budgets (`AppleAgentHarness`).
- Device tool catalog: current time, reminder/calendar reads, places
  search/current/directions, weather, and validated public web fetch.
- `places.directions` prepares a destination (`AppleDirectionsPresentation`)
  for the host to open in the map app the person picks; the harness opens no
  app itself.
- One-shot "Allow once" confirmation + receipt machinery for host-added
  mutating operations, with no persistent grants.
- Durable action-receipt journal with confirmed / uncertain / failed outcomes,
  so a possibly-committed write is never silently replayed.
- Host seams for planning, dispatching, event streams, active-operation
  tracking, and DEBUG diagnostics.
- Real Apple-framework services (EventKit, MapKit, CoreLocation, WeatherKit)
  with honest unavailable stubs on unsupported platforms.
- MIT license.
