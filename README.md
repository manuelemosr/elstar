```text
                                                  ..--==+++++++++++.
                                             .-=+**###**********##=
                                       *+ .=**#******++******###*-
                                      +*-=****+++*++**######***=
                                     -#+=++***#######*##**++=.
                                     -#=  ...---------...
                         ...--...     *+      ..----..
               ...  .--==++++++++++=-.#*.=++**########**+=..--..
          .-=====----======+++++++****************##*############*+.
         =++====-------====+++++++++*************###*###############+
        =+++====-------=====++++++++*************##**###############@*
       -++++====-------=====++++++++*************##**################@-
       =++++=====-----=====+++++++++**++********##***#################+
       =+++++==============+++++++++**..********#****#################+
       -++++++============+++++++++**=  =******##***##################=
        ++++++++========++++++++++++=    +**********#################*
        -+++++++++++++++++++++-.              .=****#################=
         +++++++++++++++++++++++-           .=*##**##################.
         =*++++++++++++++++++++***=        =*##***##################+
         .**++++++++++++++++++****.        -#****###################.
          =****+++++++++++*******=  .=**=.  +#**###################=
           =*********************-=+****#**==*####################+
            =*****************************###*##################@+
             -*****************************#####################=
              .+**************************####################*.
                .+**********************####################*-
                  .=**#***************###################*+.
                     -=**#####****####**##############*+-
                        .-=+***###**+=..=+**#####*+=-.
                              ....          ....

                        ________   ______________    ____
                       / ____/ /  / ___/_  __/   |  / __ \
                      / __/ / /   \__ \ / / / /| | / /_/ /
                     / /___/ /______/ // / / ___ |/ _, _/
                     /_____/_____/____//_/ /_/  |_/_/ |_|
```

# Elstar

**Bounded plan-act-verify device-tool harness for Apple platforms.**

Elstar lets a language model - on-device or remote - plan device goals as
plain structured values, then safely executes a fixed catalog of tool
operations against Apple frameworks. Every outcome is verified by read-back,
and the result handed back to the model is grounded, not hallucinated. The
model plans and narrates; only the harness touches the device.

Elstar is the reusable, host-agnostic core. It ships no UI, no model runtime,
and no networking policy of its own: a host app supplies those through small
seams (see [Host contract](#host-contract-what-you-provide)).

## Built on Apple frameworks

| framework | used for |
| --- | --- |
| EventKit | Reminder and calendar reads |
| MapKit | Nearby place search and directions destination resolution |
| CoreLocation | One-shot current location |
| WeatherKit | Current conditions and forecasts |
| URLSession | Validated reads of a single public web page |
| Foundation | Time, dates, and the injected clock |
| FoundationModels / remote APIs | *Not bundled* - the host supplies the planner |

## What it is (and is not)

**Is:** a library you can embed in any iOS 18+ app to let a model safely
operate on-device data - reminders, calendar, places, weather, a public web
page - under strict budgets, explicit one-shot confirmations for mutations,
and durable receipts.

**Is not:** an app, a chat UI, a model, an agent framework, or a full
"assistant". It contains no server code, no accounts, no telemetry, and no
network calls other than the user-requested public web fetch.

## Requirements

- iOS 18+ and Xcode 16+ (swift-tools 6.0).
- macOS 14+ compiles the shared logic for tests; device-only services fall
  back to honest "unavailable" stubs rather than faking success.
- WeatherKit capability for live weather on a real device.
- Info.plist usage strings for the frameworks you enable (reminders, calendar,
  location) as required by those frameworks.

## Install

Add Elstar as a Swift Package, pinned to a commit on `main`:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/manuelemosr/elstar.git", branch: "main"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "Elstar", package: "elstar"),
    ]),
]
```

```swift
import Elstar
```

## Tool catalog

Each operation id is host-facing; a host maps it to whatever model-facing
tool name its planner uses (for example `get_current_time`). The catalog and
argument contracts are shared so different transports stay identical.

| tool_name | description | interface | kind |
| --- | --- | --- | --- |
| `time.current` | Current local date, time, and time zone | Foundation (injected clock) | read |
| `reminders.list_lists` | List the person's reminder lists by name | EventKit | read |
| `reminders.list` | List open reminders with titles, due dates, and list ids | EventKit | read |
| `calendar.list` | List calendar events for a bounded range or a specific day | EventKit | read |
| `calendar.availability` | Read busy/free blocks for a range or day | EventKit | read |
| `places.current` | Resolve the device's current place (coordinate + optional address) | CoreLocation + MapKit | read |
| `places.search` | Search for nearby places matching a query | MapKit | read |
| `places.directions` | Prepare directions to a chosen place for the host's map-app chooser | MapKit reachability | read |
| `weather.current` | Current conditions, or an hourly/daily forecast | WeatherKit | read |
| `webfetch.read` | Read one public https page's visible text and links | URLSession validated fetch | read |

Every mutation asks for a one-shot **Allow once** and never receives a
persistent grant. The built-in catalog has no mutating operations: opening a
map app is the host's UI choice, so `places.directions` only reports the
destination and the host presents the installed map apps. Hosts may add
mutating operations that reuse the confirmation and receipt machinery.

## Repository structure

`Sources/Elstar/` - the library. Grouped by responsibility:

| file | what it is about |
| --- | --- |
| `AppleAgentHarness.swift` | The plan-act-verify loop: goals, plans, executed steps, prompt budgets, and `AppleAgentHarness.run(...)`. Owns the outcome and the "every goal verified" rule. |
| `AppleToolCoordinator.swift` | `AppleToolExecutor`, the single entry point that *runs one operation*: confirmation gating, result/receipt assembly, and the display `toolName`. Implements `AppleToolDispatching`. |
| `AppleToolDomain.swift` | The domain model and catalog: tool families, operations, request/result/error types, and the operation vocabulary everything else shares. |
| `AppleToolServices.swift` | The service protocols (reminders, calendar, places, weather, web fetch), the `AppleToolServices` dependency container, macOS "unavailable" stubs, the `AppleToolDispatching` / `AppleFoundationModelRuntime` seams, and the single-resume guard for repeated framework callbacks. |
| `AppleNativeToolServices.swift` | The real implementations: `EventKitRemindersService`, `EventKitCalendarService`, `MapKitPlacesService`, `OneShotLocationProvider`, `WeatherKitWeatherService`. |
| `AppleWebFetch.swift` | The public-page fetcher: URL/SSRF validation, redirect-hop limits, HTML-to-text and link extraction, and size/time limits. |
| `AppleWebFetchClient.swift` | The concrete `URLSession` HTTP client behind the `AppleWebFetchHTTPClient` protocol (injectable for tests). |
| `AppleToolResolution.swift` | Injectable clock (`AppleClock`), date/instant parsing and formatting, the current-time summary, and directions/anchor helpers. Deterministic time is why tests can advance the clock. |
| `AppleToolPiping.swift` | Durability and safety plumbing: `AppleToolJournal` (receipts), `AppleOperationSerializer` (one operation at a time), `AppleConfirmationStore` + `AppleOnceFlag` (Allow once). |
| `HarnessSeams.swift` | The host seams and shared interaction types: `HarnessConversationKey`, `HarnessToolEventSink`, `HarnessActiveOperationTracking`, `PendingInteraction`/`PendingQuestion`, and the default permission card. |
| `HarnessToolDiagnostics.swift` | DEBUG-only diagnostics protocol and scrubber for the host's developer tooling. Absent from release behavior. |
| `DeviceAgentPlannerSupport.swift` | The model-agnostic planner surface: prompt builders, operation contracts, `DeviceAgent*` decision DTOs, the request builder, and step selection/resolution. Shared by any planner. |
| `AppleIntelligenceAvailability.swift` | Availability value plus honest reasons/recovery when the built-in model cannot answer. |

`Tests/ElstarTests/` - package-level tests. `Package.swift`, `LICENSE` (MIT),
and this README round out the package.

## Host contract (what you provide)

Elstar depends on the host through narrow protocols. A host app typically
wires:

1. **A planner** - `AppleAgentPlanner` (`plan`, `nextStep`, `reconsider`).
   Wrap your model (on-device or remote) so it returns plain
   `AppleAgentPlan` / `AppleAgentStep` values. Elstar never calls a model
   directly and never parses English keywords.
2. **A dispatcher** - `AppleToolExecutor` (you construct it and pass it as
   `any AppleToolDispatching`).
3. **An event sink** - `HarnessToolEventSink` to receive tool deltas, action
   receipts, and permission interactions and map them into your UI.
4. **Active-operation tracking** - `HarnessActiveOperationTracking` so the
   host knows which operation is in flight.
5. **Native services** - `AppleToolServices(...)` with the real services, or
   the `Unavailable*` stubs on platforms without a given framework.
6. **Optional diagnostics** - `HarnessDiagnosticRecording` (DEBUG builds
   only).

### Minimal wiring

```swift
import Elstar

// 1. One executor per conversation turn.
let services = AppleToolServices(
    reminders: EventKitRemindersService(),
    calendar: EventKitCalendarService(),
    places: MapKitPlacesService(),
    weather: WeatherKitWeatherService(),
    webFetch: ApplePublicWebFetcher()
)

let executor = AppleToolExecutor(
    key: HarnessConversationKey(absoluteKey: "connection/conversation"),
    messageID: "turn-1",
    tracker: myActiveOperationTracker,
    sink: myEventSink,
    serializer: AppleOperationSerializer(),
    confirmations: AppleConfirmationStore(),
    journal: AppleToolJournal(fileURL: AppleToolJournal.defaultURL(connectionID: id)),
    services: services
)

// 2. Run the bounded loop with your planner.
let harness = AppleAgentHarness(planner: myPlanner, dispatcher: executor)
let outcome = await harness.run(task: userText, history: history, goals: plannedGoals)
```

## Extending

To add an operation: add the case and request to `AppleToolDomain.swift`, add
(or reuse) a service protocol in `AppleToolServices.swift`, implement it in
`AppleNativeToolServices.swift`, add the executor arm in
`AppleToolCoordinator.swift`, and describe it in `DeviceAgentPlannerSupport.swift`
so planners can plan it. Reads should verify by read-back; mutations must go
through `AppleConfirmationStore` and write a journal receipt.

## Testing

```bash
swift build
swift test
```

On a machine whose active toolchain is the Command Line Tools, prefix with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` so the Swift
Testing macro plugin resolves.

## Status and roadmap

- Package-level tests cover the domain catalog, the executor, the journal and
  serializer, plan-act-verify, and the web-fetch boundary.
- Planned: a demo/example app that exercises confirmations and tool cards, a
  `Docs/` site, and a tagged `1.0` release.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT - see [LICENSE](LICENSE).
