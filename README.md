# Elstar

**A reusable iOS agent harness for the tools and everyday use cases of iPhone and iPad apps.**

Elstar is a Swift package that helps an AI-powered iOS app use device features
such as Calendar, Reminders, Maps, location, Weather, and the current time. Its
goal is to provide the safe layer between an AI model and those iOS tools: the
model decides what it needs, and Elstar runs only supported operations and
reports what actually happened. Your app supplies the model and the interface
people see.

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

## What can it help with?

An app using Elstar could handle requests like these:

| Someone asks | Elstar can help the app |
| --- | --- |
| “What's on my calendar tomorrow?” | Read events or check when the person is free. |
| “What reminders do I still have?” | Read reminder lists and open reminders. |
| “Find coffee near me.” | Get the current place and search nearby places. |
| “How do I get there?” | Prepare a destination so the app can offer a choice of installed map apps. |
| “What's the weather this afternoon?” | Read current conditions or a forecast. |
| “What time is it here?” | Read the device's local date, time, and time zone. |
| “Read this web page.” | Fetch the visible text and links from one public HTTPS page. |

**Today, all built-in tools are read-only.** Elstar does not add, change, or
delete reminders or calendar events. It prepares directions but leaves the
choice to open a map app to the host app and the person using it. A host can
add its own tools that change data; those must ask for **Allow once** and keep
a record of what happened.

## How it works

1. Your app's AI model makes a plan for the person's request.
2. Elstar checks the plan against its supported tools and limits how many
   steps it can take.
3. Elstar calls the relevant iOS framework, checks the result, and tells the
   model whether the goal was met or why it failed.
4. Your app shows the answer, results, and any permission choices in its own
   interface.

The model cannot call iOS APIs directly through Elstar. Elstar is the part
that controls which tool runs and returns a result grounded in the device's
response.

## What your app provides

Elstar is a library, not a finished assistant or chat app. The host app
provides:

- An AI model, either on the device or through the app's own remote service.
- The screen where people ask questions and see answers and tool activity.
- The iOS permissions and capabilities needed for the features it enables.
- The choice of map app when someone asks for directions.

Elstar has no accounts or telemetry. It does not include a model, chat UI, or
networking for a remote model. Its built-in network access is limited to the
user-requested public web-page reader.

## Requirements

- iOS 18+ and Xcode 16+ (Swift tools 6.0).
- WeatherKit capability to provide live weather on a real device.
- The required `Info.plist` usage descriptions for reminders, calendar, and
  location when the app uses those features.
- macOS 14+ can compile the shared logic for tests; iOS-only services report
  that they are unavailable instead of pretending to work.

## Add Elstar to an app

Add the Swift package to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/manuelemosr/elstar.git", branch: "main"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "Elstar", package: "elstar"),
    ]),
]
```

Then import it in Swift:

```swift
import Elstar
```

## Built-in tools

These are the operation IDs an app uses when it connects its model to
Elstar. An app can present friendlier names to the model.

| Operation ID | What it reads or prepares | Apple API |
| --- | --- | --- |
| `time.current` | Local date, time, and time zone | Foundation |
| `reminders.list_lists` | Reminder lists | EventKit |
| `reminders.list` | Open reminders and due dates | EventKit |
| `calendar.list` | Events for a day or date range | EventKit |
| `calendar.availability` | Busy and free times | EventKit |
| `places.current` | Current place and optional address | CoreLocation, MapKit |
| `places.search` | Nearby places matching a search | MapKit |
| `places.directions` | A destination for the app's map chooser | MapKit |
| `weather.current` | Current weather or a forecast | WeatherKit |
| `webfetch.read` | Text and links from one public HTTPS page | URLSession |

## Connect it to your app

Elstar needs a few pieces from the host app: an `AppleAgentPlanner` that wraps
the model, an `AppleToolExecutor` that runs tools, an event sink that forwards
results to the UI, active-operation tracking, and the Apple services the app
enables. Developer diagnostics are optional and available only in DEBUG
builds. The [architecture guide](docs/ARCHITECTURE.md) explains how these
pieces fit together.

Here is the basic wiring. The app supplies `myPlanner`, `myEventSink`,
`myActiveOperationTracker`, `id`, `userText`, `history`, and `plannedGoals`:

```swift
import Elstar

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

let harness = AppleAgentHarness(planner: myPlanner, dispatcher: executor)
let outcome = await harness.run(task: userText, history: history, goals: plannedGoals)
```

To add a tool, define its operation and request in `AppleToolDomain.swift`,
implement its service, connect it in `AppleToolCoordinator.swift`, and describe
it in `DeviceAgentPlannerSupport.swift` so a model can plan it. Tools that
change data must use `AppleConfirmationStore` and record a receipt in
`AppleToolJournal`.

The library lives in `Sources/Elstar/`, with package tests in
`Tests/ElstarTests/`. See the [architecture guide](docs/ARCHITECTURE.md) for
the request flow and safety rules.

## Build and test

```bash
swift build
swift test
```

If the active toolchain is the Command Line Tools, prefix these commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` so the Swift
Testing macro plugin resolves.

## Project status

Package tests cover the tool catalog, execution, receipts, and the web-page
reader. A demo app, a documentation site, and a tagged 1.0 release are
planned.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT - see [LICENSE](LICENSE).
