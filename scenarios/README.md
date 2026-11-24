# SDK scenarios

Scripted journeys through an SDK, written as **the calls an app makes** — `init`, `track`,
`identify`, `setPersonProperties`, `setConsent`, `reset`, `flush` — never as the envelopes that go
over the wire. That is what lets one file drive every SDK, and what makes `expected/` a contract a
second SDK must reproduce: replay the same scenario, produce the same batches.

The fixture is one customer, a B2C subscription app with a web front end and a payment provider:
acquisition, sign-up, onboarding, paywall, trial, conversion, renewal and churn, plus the edge
cases an analytics pipeline fails silently on.

| Path                         | What it is                                                                                                                 |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `scenarios/*.json`           | One person's journey each ([`scenario.schema.json`](scenario.schema.json))                                                 |
| `fragments/*.json`           | Steps shared by scenarios, inlined by `include`                                                                            |
| `mixes/*.json`               | A population: each scenario run `weight` times ([`mix.schema.json`](mix.schema.json))                                      |
| `funnels.json`               | The funnels a mix is read through; step counts are computed from the mix                                                   |
| `definitions/*.json`         | The customer's defined events: the server-sent ones and the onboarding events                                              |
| `expected/*.json`            | Each scenario's batches under a fixed clock and seed — the golden envelopes; random ids and `sdk.version` are placeholders |
| `native/*.json`              | One app's life on one device, for native SDKs only ([`native-scenario.schema.json`](native-scenario.schema.json))          |
| `expected-native/`           | Each native scenario's batches, recorded by the Swift runner ([Native scenarios](#native-scenarios))                       |
| `fixtures/property-cap.json` | Key sets every SDK's property cap is checked against: past 256, which keys survive in UTF-16 code-unit order               |

## Running one

From `sdks/browser`, after `npm run build`:

```bash
node scripts/run-scenario.mjs trial_converts --endpoint http://127.0.0.1:8788 --write-key togo_pkl_…
node scripts/run-scenario.mjs b2c_subscription_week --endpoint … --write-key …
node scripts/run-scenario.mjs trial_converts --record          # print the batches, send nothing
npm run scenarios:record                                       # re-record expected/, then read the diff
```

A send checks the key once (`GET /v1/key`), and exits non-zero unless every upload was accepted,
every `expectRejected` came back, nothing else was refused, and per event name exactly the events
the plans deliver were accepted. The SDK cannot report any of that itself: `flush()` never throws,
and a `401` disables the client with one console line. `npm test` re-records every scenario against
the source and diffs it against `expected/`.

## The format

```json
{
  "$schema": "../scenario.schema.json",
  "name": "trial_converts",
  "description": "Signs up, finishes onboarding, starts a trial, uses the product, converts.",
  "steps": [
    { "include": "acquisition" },
    { "include": "onboarding_happy_path" },
    { "include": "trial_checkout" },
    {
      "track": "core_action_completed",
      "properties": { "action_id": "session_played" },
      "at": "+2d"
    },
    {
      "track": "subscription_started",
      "actor": "server",
      "at": "+3d",
      "properties": {
        "plan_id": "premium",
        "billing_period": "annual",
        "amount_minor": 5999,
        "currency": "USD",
        "is_trial_conversion": true
      }
    }
  ]
}
```

A scenario has `name` (its file name), `description`, optional `init` (the SDK options a scenario
may set: `consent`, `onDenied`, `sessionTimeoutSeconds`, and `defaultProperties`, which
the server sender takes too), optional `deviceClockOffsetMs`,
and `steps`. A step is **exactly one verb** — the SDK's public API, plus `include` — and,
optionally, the runner's own keys:

| Key              | Means                                                                                                                       |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `at`             | `+40s`, `+1d2h` after the previous step; omitted, a seeded 2–20 s. `now±<duration>` is absolute, only with `expectRejected` |
| `actor`          | `client` (default) or `server` — below                                                                                      |
| `device`         | Which of the visitor's devices; default `browser`. A new name is a fresh `init()` with its own storage                      |
| `expectRejected` | The `RejectionCode` the edge must return for this event — the one way a step may break a limit on purpose                   |

Strings may use `{{userId}}` (unique per run and visitor), `{{n}}` (the visitor's number) and
`{{chars:N}}` (N characters, for a value over a cap). **A verb is added when every SDK that reads
the format can perform it**, never ahead of one.

`scenario.schema.json` is for editors; the runner's validator
([`sdks/browser/scripts/scenarios/format.mjs`](../browser/scripts/scenarios/format.mjs)) is the authority and
refuses more: an absolute `at` without `expectRejected`, a span the window cannot hold, more than
one upload's worth of events on a device, an unknown verb, key or `init` option, a server step
that is not a `track` or names a device, a `$` name, a nested property, a circular or missing
`include`.

**`actor: "server"`** marks what a real product sends from its backend — the payment provider's
webhook, not the browser. The runner sends it through the server SDK, `@togohq/sdk-node`, naming
the visitor's `userId` on every call: no device, no session, no `identify()`, and no id the SDK
made up. Its events land as `sdk.name = "sdk-node"` and `event_source = "server"`, on the same
person as the browser's once the browser has identified. Through the browser's client it would
carry the browser's device and session and count in a session that never saw it.

**A mix** is a seed and `{ scenario, weight }` pairs. Weights are exact counts, so every funnel's
step counts are computable from the file — the runner prints them from `funnels.json`. The week:
F1 994 → 395 → 195, F3 115 → 65 → 65 → 65, F4 55 → 25 → 25, F6 3 → 3. One floor on the weights:
**every defined event is sent by at least three people**, so no defined event's chart is one
person's behaviour.
`b2c_subscription_smoke` is the same scenarios a handful each, for an end-to-end test.

## Time

**A faked device clock does not backdate an event.** The edge sets
`event_time = clientEventTs + (receivedAt − clientSentTs)`, so a device whose whole clock is days
behind is a skewed device, corrected to now. What lands in the past is an event queued offline and
uploaded later. So the runner ([`drive.mjs`](../browser/scripts/scenarios/drive.mjs)):

1. **Places** each visitor at a seeded point in the last six and a half days, late enough that its
   last step lands before now.
2. **Plays every step offline** on a virtual `Date`, with the network held — `/v1/events` rejects
   as offline, which the SDK re-queues — and the SDK's own flush timer pushed past the run, since
   an upload it fired mid-scenario would carry a past `clientSentTs` and be corrected to now.
3. **Releases** the network with each device clock reading now. Every event keeps its planned
   time. A `flush` step is the same release for one device mid-scenario — how a scenario says
   "this was sent before that", which `consent_withdrawn` needs, because a denial purges what is
   still queued.

**Each device gets its own storage** — a cookie jar, `localStorage` and a `location`. Under Node
the SDK has no `document`, and its fallback store is module-level by design, so that two `init()`s
on one page agree; in one process every client would then share one device id, one anonymous id,
one `userId` and one session. A per-device jar is also what a browser has.

| Limit                   | Value                 | Consequence                                                                                    |
| ----------------------- | --------------------- | ---------------------------------------------------------------------------------------------- |
| Event age, edge and SDK | 7 days                | Relative steps span at most 6 days 11 hours. A five-day trial fits; a monthly renewal does not |
| Event in the future     | 5 minutes             | `at` never passes now, except an absolute `at` with `expectRejected`                           |
| Batch size              | 500 events per upload | At most 500 events per device, so a device is one upload                                       |

Renewals therefore appear as renewals of subscriptions that began before the window — which is
also what a real week of traffic looks like.

## The customer

Every name and key it defines is lowercase `snake_case` (`event_names` and `property_names` exist to send ones that
are not), and every property is a boolean, a number or a fixed-vocabulary enum. Email addresses
are `@example.com` and go on the profile through `setPersonProperties`' typed `email` and `name`
(sent as `$email` and `$name`), never on an event. No `properties` map carries a `$` key: reserved
properties travel in typed envelope objects, and the validator refuses one.

**Defined, and only sent.** It defines four onboarding events (`onboarding_started`,
`onboarding_step_completed`, `onboarding_completed`, `onboarding_abandoned`;
`flow_id = initial_setup`, steps `choose_goals`, `set_reminder`, `first_session`, and `entry_point`
on `onboarding_started`). It defines its seven server events, where a definition
earns its keep — `amount_minor` and `currency` are the shape a revenue chart depends on. Its nine
client events are only sent, and reach the registry from traffic, as most of a real customer's do.

| Event                      | Properties                                                                                                     | Actor  | Does not fire                                    |
| -------------------------- | -------------------------------------------------------------------------------------------------------------- | ------ | ------------------------------------------------ |
| `page_viewed`              | `page_type` (`landing \| pricing \| features \| blog \| account`)                                              | client | on a re-render that showed no new page           |
| `account_created`          | `method` (`email \| google \| apple`)                                                                          | client | on signing in to an existing account             |
| `signed_in`                | `method`                                                                                                       | client | on a session restored from a stored credential   |
| `paywall_viewed`           | `placement` (`onboarding_end \| feature_gate \| settings`), `offer_id` (`trial_5d \| annual_discount \| none`) | client | when prefetched or off-screen                    |
| `paywall_dismissed`        | `placement`                                                                                                    | client | when the person leaves by selecting a plan       |
| `plan_selected`            | `plan_id` (`basic \| premium`), `billing_period` (`monthly \| annual`)                                         | client | on hovering or comparing plans                   |
| `checkout_started`         | `plan_id`, `billing_period`                                                                                    | client | on re-opening a checkout in progress             |
| `checkout_failed`          | `plan_id`, `failure_reason`                                                                                    | client | on a validation error corrected without resubmit |
| `core_action_completed`    | `action_id` (`session_played \| goal_logged \| reminder_set`)                                                  | client | when started and not finished                    |
| `trial_started`            | `plan_id`, `trial_days`                                                                                        | server | when checkout completes, before the provider     |
| `subscription_started`     | `plan_id`, `billing_period`, `amount_minor`, `currency`, `is_trial_conversion`                                 | server | on a trial starting                              |
| `trial_expired`            | `plan_id`                                                                                                      | server | when the trial converts                          |
| `subscription_renewed`     | `plan_id`, `billing_period`, `amount_minor`, `currency`, `renewal_number`                                      | server | on the first charge                              |
| `payment_failed`           | `plan_id`, `failure_reason`, `attempt_number`                                                                  | server | on a checkout-time failure                       |
| `subscription_cancelled`   | `plan_id`, `cancel_reason`, `at_period_end`                                                                    | server | when a trial lapses unconverted                  |
| `subscription_reactivated` | `plan_id`                                                                                                      | server | on a new subscription after the old one ended    |

Money is `amount_minor` plus `currency` — an integer in the minor unit, because a float price is
how revenue charts drift by a cent per thousand rows. The near-duplicates are deliberate:
`checkout_failed` (client, at checkout) and `payment_failed` (server, at renewal) are different
moments; `trial_expired` and `subscription_cancelled` are different decisions.

**The funnels** (`funnels.json`): F1 acquisition → sign-up; F2 onboarding activation; F3 paywall →
checkout; F4 trial → paid; F5 renewal and recovery; F6 voluntary churn. F3 and F4 mix undefined
client steps with defined server steps, the shape a customer's funnel has.

## The scenarios

| Scenario                   | Path                                                                                                                    | Carries                                                                                                                                                |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `bounce`                   | one `page_viewed[landing]`                                                                                              | An anonymous person, never materialised                                                                                                                |
| `browse_no_signup`         | landing → pricing → features, a day apart                                                                               | A session cut by the 30-minute idle timeout                                                                                                            |
| `signup_no_onboarding`     | F1, `identify`, nothing after                                                                                           | `identify()` linking the anonymous history                                                                                                             |
| `onboarding_abandoned`     | F1, onboarding started, step 1, abandoned                                                                               | The abandonment branch                                                                                                                                 |
| `paywall_dismissed`        | F1, F2, paywall shown and dismissed                                                                                     |                                                                                                                                                        |
| `trial_expires`            | F1–F3 into a trial, no product use, `trial_expired`                                                                     | Server events, sessionless, in a client funnel                                                                                                         |
| `trial_converts`           | the example above                                                                                                       | The five-day offline replay                                                                                                                            |
| `direct_purchase`          | F1, then `signed_in` on a phone, F3 into `subscription_started`                                                         | Two devices, one person                                                                                                                                |
| `payment_failed_recovered` | two failed renewal charges, then a renewal                                                                              | A subscription that began before the window                                                                                                            |
| `subscriber_cancels`       | cancelled at period end, then reactivated                                                                               |                                                                                                                                                        |
| `skewed_device`            | `trial_converts` with the device clock 3 h behind                                                                       | The same event times once corrected                                                                                                                    |
| `consent_withdrawn`        | pending → events → granted → events → `flush` → denied → an event                                                       | Buffered events released on grant; nothing after the denial                                                                                            |
| `not_defined_property`     | `subscription_started`, defined, with an extra `coupon_code`                                                            | An undefined property written and observed                                                                                                             |
| `email_in_property`        | `checkout_failed` with an email address in `contact`                                                                    | That property dropped and counted; the rest lands                                                                                                      |
| `event_names`              | `Sign Up`, then `Sign up`                                                                                               | Two events, each named exactly as sent; the second looks like the first                                                                                |
| `property_names`           | `Plan Type` from the browser and the server, then `plan type`, `planType`, `Playn Type`                                 | Property names stored as sent; one property from two actors                                                                                            |
| `invalid_property_names`   | a property name over 255 characters, one with a tab, one with an email address, from both senders                       | Each reported through `onError`; sent under a test key for `property_name_invalid`, dropped under a live key                                           |
| `rejected_events`          | good events, a value over 1,024 characters, an event with 300 properties, an event 10 minutes in the future — one batch | The future event refused on its own; the long value cut to 1,024 and kept; the wide event keeps its first 256 properties in sort order; the rest lands |
| `default_properties`       | `init({ defaultProperties })`, a page view, `identify`, an override, a server event                                     | Defaults on every `track()` from both senders, never on `$identify`; event wins                                                                        |

The edge cases (`skewed_device` and below) are not in a mix: they run by name and as golden
fixtures. `event_names` especially, since the names it registers stay in the project it runs
against. Two things a Node runner cannot see, and does not claim to: whether a consent
withdrawal deletes the stored keys (the SDK's own consent tests, against a real cookie jar), and
anything a real browser engine does differently from the jar above.

## A second SDK: the Swift runner

`sdks/ios` replays the same files through its Swift core, with no simulator and on Linux too. The
runner is the `TogoScenarios` target — a port of `format.mjs`'s planner, exact down to `mulberry32`
in unsigned 32-bit arithmetic, since the seeded gaps decide every `clientEventTs` — and its test
replays every scenario on `swift test`:

```bash
cd sdks/ios
swift test                                # every scenario against expected/, among the suite
swift run togo-scenarios                  # the same check, one line per scenario
swift run togo-scenarios --print bounce   # the recorded batches, projected
```

**It never writes `expected/`** (it does write `expected-native/`, below). The browser SDK records the goldens; the Swift runner reads them
and must reproduce them, through one documented projection (`Projection` in
`sdks/ios/Sources/TogoScenarios/Normalize.swift`) that removes only what a phone cannot match:

| Removed              | From          | Because                                                                                   |
| -------------------- | ------------- | ----------------------------------------------------------------------------------------- |
| `server` batches     | the golden    | `@togohq/sdk-node` sends them; a device SDK replays the device steps only (Conformance 1) |
| `page` on each event | the golden    | Only the web has a URL                                                                    |
| `deviceIdMode`       | both          | `cookie` on the web; `install`, then `idfv`, on iOS                                       |
| `app` and `device`   | the recording | The browser's goldens carry neither; the iOS SDK always sends both                        |
| `sdk.name`           | compared as   | `sdk-ios` rather than `sdk-browser`                                                       |

Everything else must be equal: which events, in what order, at what times, in which sessions,
under which ids (placeholders renumbered on both sides after the removal), with which properties,
profile writes and time zone, under each consent state. A verb this runner cannot perform fails the
load rather than being skipped, which is why a verb is added only when every SDK reading the format
can perform it. The three scenarios with only `server` steps compare as empty on both sides.

## A third SDK: the Kotlin runner

`sdks/android` replays the same files through its Kotlin core, on a plain JVM with no emulator and
no Android SDK. The runner lives in the core's test sources (`core/src/test/kotlin/ai/togohq/scenarios`)
— a port of the same planner, `mulberry32` in wrapping 32-bit `Int` arithmetic — and its test
replays every scenario on `./gradlew build check`:

```bash
cd sdks/android
./gradlew :core:test                                    # every scenario against expected/, among the suite
./gradlew :core:scenarios                               # the same check, one line per scenario
./gradlew :core:scenarios --args="--print bounce"       # the recorded batches, projected
./gradlew :core:scenarios --args="--native"             # every native scenario against expected-native/
```

**It writes neither `expected/` nor `expected-native/`**: it has no record mode at all. Its
`Projection` removes what the Swift runner's does — `server` batches and `page` from the golden,
`deviceIdMode` from both, `app` and `device` from the recording — and compares `sdk.name` as
`sdk-android`. A difference is a bug in the Kotlin core, never a new golden.

**It replays `native/` too**, against `expected-native/` ([Native scenarios](#native-scenarios)),
driving the core's activity counter exactly as the Android adapter does: a `foreground` or
`background` names an activity, and the 700 ms delay before a background runs on the virtual clock.
The native format names no install time, which Android's install rule reads (`$app_installed` only
for an install at most seven days old), so the runner takes the first `launch` as the install —
every native scenario's first launch is a new one — and the iOS goldens match unchanged.

## Native scenarios

`native/` holds what only an app can do: be **launched** (a new process over what the last one
stored, reporting a build), and have scenes come to the **foreground** and go to the **background**.
Those are the three verbs a native scenario adds to the device verbs, and what the app lifecycle
events — `$app_installed`, `$app_updated`, `$app_opened` — and the lifecycle session rules are pinned by. A browser
cannot perform any of them, so these files live in their own directory: the browser runner and
`sdk-node` never list them, and `scenarios/` keeps its rule that a verb is added only when every SDK
reading the format can perform it.

```bash
cd sdks/ios
swift test                                   # every native scenario against expected-native/, among the suite
swift run togo-scenarios app_updated         # the same check, for one
swift run togo-scenarios --record-native     # re-record expected-native/, then read the diff
```

**The first native SDK records the goldens, and every later one is held to them.** `sdk-ios` wrote
`expected-native/`, as the browser wrote `expected/`; `sdk-android`'s runner reads the same files and
removes only what a different platform cannot match — `device`, `deviceIdMode` and `sdk.name` — the
way the Swift runner's `Projection` treats the browser's goldens. Re-recording is a deliberate
change to the contract: read the diff, because a lifecycle rule that broke shows up there as a
plausible-looking new golden.

A native scenario has one device and no `server` actor, starts with a `launch`, and names the
scene for each `foreground` and `background`. The network is held until the end, as for every
scenario, so the background flushes fail like an offline phone's and each event is uploaded with
its real `clientEventTs`; a batch never mixes two app builds. What a native scenario does **not**
cover is what no runner can fake honestly — a device locked before its first unlock, an IDFV that
is nil, the files' backup and protection flags — and those are the SDK's own tests
(`sdks/ios/Tests/TogoCoreTests/LifecycleTests.swift`, `IdentityFileTests.swift`; in `sdks/android`,
`LifecycleTest.kt`, `IdentityFileTest.kt` and the adapter's Robolectric `AdapterTest.kt`).
