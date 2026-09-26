# Shop: a modular Rails application built with EventRail

A small online shop — checkout, payment, shipping, cancellation, returns, loyalty points and customer notifications — split into modules inside one Rails application. It exists to show two things at once:

- **How modules in one Rails application talk to each other.** A method call where the caller needs the answer now. An asynchronous command where the caller owns a step but need not wait for it. An event only for a fact the publisher would be complete without anyone hearing. And why each interaction below is the one it is.
- **What EventRail adds when an event is the right tool.** Each subscriber is an ordinary Active Job with its own retries. An event keeps its identity across retries and redeliveries. Every flow carries a correlation you can follow. And a module can join by subscribing, with no existing module changing.

It is not a real shop — no sign-in, no real payment provider, no storefront design — and it is not event sourcing. Everything that would hide the point was left out.

## Run it

```sh
cd examples/shop
bin/setup   # installs gems, creates both databases, seeds products and customers, starts the server
```

Then open <http://localhost:3000>. After the first time, `bin/dev` starts it again. Requires Ruby 3.3 or newer; the databases are SQLite files in `storage/`.

`bin/setup` is safe to run again after pulling changes: it keeps your data and applies what is new. To start over with a fresh shop instead — the demo data discarded, both databases rebuilt from `db/schema.rb` and seeded — run `bin/setup --reset`.

`bin/dev` is the only process: Solid Queue's dispatcher, scheduler and workers run inside Puma, so jobs and EventRail subscribers run as soon as the server does. The terminal shows web requests; jobs log to `log/jobs.log` (`tail -f log/jobs.log`), because some run every second even while the simulator is off. Set `RAILS_LOG_LEVEL=debug` to see every SQL query.

## A tour of the console

| Page | What to look at |
| --- | --- |
| **Console** | Start the simulator; dial in faults; watch the live feed of published events |
| **Orders** | One column per module — Orders, Payments, Fulfillment, Loyalty — each that module's own view of the order. They fill in at different moments: that is eventual consistency, visible |
| **Order** (click one) | Its whole flow as a tree: every event under the job that published it, every job under what caused it, every attempt with its error |
| **New order** | Check out by hand. *Submit it twice at once* sends the same checkout twice, concurrently — and gets one order |
| **Architecture** | The module graph read from `package.yml`, and which subscribers were seen reacting to which events |
| **Jobs** | Mission Control: the queue itself. Every subscriber delivery is an ordinary job, with its own queue and retries |

Things to try:

1. **Start the simulator** at 60 orders a minute and open an order: `orders.order_placed`, the capture, the shipment, delivery, points.
2. **Set "payment provider times out" to 40%.** Open a new order's flow: the capture job fails an attempt or two and then succeeds. Nothing else in the shop noticed.
3. **Break Loyalty** — make `Loyalty::AwardPointsJob` fail its next 5 runs. Orders keep being delivered; Loyalty retries on its own schedule and catches up. Its failures are visible in its own branch of the tree, and in Jobs.
4. **Set "capture refused" to 100%.** Orders are placed, then cancelled: stock released, card hold voided, customer notified — and nothing ships.
5. **Cancel a paid order** from its page before it ships, or **return a delivered one**: the refund appears as a new branch of the same flow.

## The modules

Each module is a Rails engine under `engines/`, with one namespace named after it and the standard engine layout, so Rails' generators keep working.

| Module | Owns | Calls | Publishes (`<Module>::Events`) | Listens to |
| --- | --- | --- | --- | --- |
| `Platform` | base classes, demonstration fault settings | — | — | — |
| `Catalog` | products, prices, stock, reservations | — | — | — |
| `Payments` | authorizations, captures, voids, refunds; a fake gateway | — | `PaymentCaptured`, `CaptureFailed`, `AuthorizationVoided`, `RefundIssued`, `RefundFailed` | — |
| `Fulfillment` | shipments and returns; a fake carrier | — | `ShipmentDispatched`, `ShipmentDelivered`, `ReturnReceived` | — |
| `Orders` | orders and their whole lifecycle | Catalog, Payments, Fulfillment | `OrderPlaced` (v2, v1 kept), `OrderShipped`, `OrderDelivered`, `OrderCancelled`, `OrderRefunded` | Payments, Fulfillment |
| `Notifications` | customer notifications (recorded, not emailed) | — | — | Orders |
| `Loyalty` | a points ledger | — | — | Orders |
| `Observability` | flow records for the console | — | — | instrumentation only |
| `Simulation` | simulated customers and supplier | Catalog, Orders | — | — |

The host application in `app/` is the developer console. It composes the modules and reads them only through their public APIs.

```
                 Console (host app)
                        │
    Notifications   Loyalty   Simulation ─────────┐
          ╎            ╎          │               │
          ╎╌╌╌╌╌╌╌╌╌╌╌╌╎╌╌╌╌╌╌╌╌╌╌▼               │
                      Orders ─────────────────────┤
          ┌──────────────┼──────────────┐         │
          ▼              ▼              ▼         ▼
       Payments     Fulfillment      Catalog ◄────┘      Observability
          └──────────────┴──────┬───────┴──────────────────────┘
                                ▼
                             Platform

   ───►  may call (and hear)          ╌╌╌  hears published events only
```

Calls point one way: down. Catalog, Payments and Fulfillment know nothing above them — Payments moves money *for a reference* and Fulfillment ships *to a reference*; neither knows what an order is. Notifications and Loyalty depend only on Orders' published events, and nothing depends on them, on Observability or on Simulation. Packwerk enforces all of it in CI (see [Boundaries](#boundaries-enforced-not-described)).

## What goes where

One question decides between a call, a command and an event: **if nobody reacted, would the publisher's own process be incomplete?**

- **Yes** — then the step is the publisher's to cause. A **synchronous call** when it cannot continue without the answer. An **asynchronous command** — a module's API method that enqueues that module's own job — when the work is slow, unreliable or behind an external provider, and the caller can carry on in a pending state.
- **No** — then it is someone else's business, and it is an **event**.

Every interaction between two modules in this application:

| Interaction | Mechanism | Why |
| --- | --- | --- |
| `Catalog::Api.quote` | sync query | checkout needs the price now |
| `Catalog::Api.reserve` | sync command | the customer must hear "out of stock" now |
| `Catalog::Api.release` | sync command | undoing Orders' own reservation, on a rejected checkout attempt or a cancellation |
| `Catalog::Api.ship` | sync command | the reserved stock leaves the warehouse when the parcel is dispatched |
| `Catalog::Api.restock` | sync command | a returned parcel goes back on the shelf |
| `Catalog::Api.products` | sync query | the simulator picks what to buy |
| `Catalog::Api.receive_stock` | sync command | the simulated supplier refills a low shelf |
| `Payments::Api.authorize` | sync command, calls the provider | a declined card must show at checkout |
| `Payments::Api.capture` | async command | the provider is slow and flaky; Orders waits for the outcome event |
| `Payments::Api.void` | async command | releasing the card hold a rejected checkout attempt placed |
| `Payments::Api.release` | async command | a cancellation gives back whatever the payment holds; Payments decides between void and refund, because only Payments knows whether a capture has landed |
| `Payments::Api.refund` | async command | giving money back for a returned parcel |
| `Fulfillment::Api.request_shipment` | async command | the carrier works on its own schedule |
| `Fulfillment::Api.cancel_shipment` | sync command | a cancellation must know now whether the parcel has left, and only Fulfillment knows |
| `Fulfillment::Api.expect_return` | async command | the carrier brings the parcel back when it does |
| `Orders::Api.checkout` | sync command | the simulator is a client placing orders |
| `Orders::Api.cancel` | sync command | a simulated customer changing their mind |
| `Orders::Api.request_return` | sync command | a simulated customer sending an order back |
| `Orders::Api.recent` | sync query | the simulator picks an order to cancel or return |
| `subscribes_to Payments::Events::PaymentCaptured` | event (Orders) | the outcome of Orders' capture command: pay, then ship |
| `subscribes_to Payments::Events::CaptureFailed` | event (Orders) | the outcome of Orders' capture command: cancel |
| `subscribes_to Payments::Events::RefundIssued` | event (Orders) | the outcome of Orders' refund command: complete the return |
| `subscribes_to Payments::Events::RefundFailed` | event (Orders) | the outcome of Orders' refund command: set the order aside |
| `subscribes_to Fulfillment::Events::ShipmentDispatched` | event (Orders) | Fulfillment cannot call upward; Orders hears the carrier's progress |
| `subscribes_to Fulfillment::Events::ShipmentDelivered` | event (Orders) | as above |
| `subscribes_to Fulfillment::Events::ReturnReceived` | event (Orders) | as above: restock and refund |
| `subscribes_to Orders::Events::OrderPlaced` | event (Notifications) | Orders is complete without anyone hearing it |
| `subscribes_to Orders::Events::OrderPlacedV1` | event (Notifications) | version 1 messages still in the queue (see [Versioning](#an-event-that-changed-shape)) |
| `subscribes_to Orders::Events::OrderShipped` | event (Notifications) | as above |
| `subscribes_to Orders::Events::OrderDelivered` | event (Notifications, Loyalty) | a Loyalty outage must never delay a delivery |
| `subscribes_to Orders::Events::OrderCancelled` | event (Notifications) | as above |
| `subscribes_to Orders::Events::OrderRefunded` | event (Notifications, Loyalty) | as above |

Inside a module, work with one known handler is a plain job, not an event: checkout's follow-up, the carrier's scheduled steps, the capture itself, the expiry scan, the simulator's tick. An event would add indirection and nothing else. For the same reason this shop has **no internal events**: none passed the question above, and a plain job does the same work with less machinery.

### Anti-patterns this design avoids

- **The disguised command.** "Payments captures the payment when it hears `OrderPlaced`" reads like decoupling. It hides a required step of the order's own process inside another module's subscriber — if that subscriber is removed or broken, orders are silently never charged — and it teaches Payments what an order is. Getting paid is Orders' job, so Orders *commands* it and *listens* for the outcome.
- **Questions through events.** `PriceRequested` answered by `PriceProvided` is request/reply rebuilt on a queue. When you need an answer, call.
- **Calling the periphery synchronously.** Awarding points or notifying the customer inside checkout would turn a Loyalty or Notifications outage into a checkout outage.
- **An orchestration layer for flows that have an owner.** Return, refund and close belong to Orders, which already depends on Payments and Fulfillment. A separate processes layer earns its place only for a flow that no module owns.

## The flows

**Checkout** decides synchronously, because the customer is waiting (`Orders::Checkout`):

```
quote prices → reserve stock → authorize card → commit the order with Orders::FollowUpJob staged → hand the job to the queue
```

Each run under a checkout key is an **attempt** with a reference of its own, `<key>/<attempt id>`, which is what Orders gives Catalog and Payments. A failure before the commit gives back what *this attempt* took — its reservation, its authorization — and is reported to the caller, so a rejected checkout leaves nothing held, and a retry starts clean: it cannot trip over a released reservation or a void still in the queue. Two submissions of the same key at once both run as attempts; the unique key lets one order through, and the other gives back its own reservation and authorization and returns that order. The follow-up job announces `OrderPlaced` and asks Payments to capture.

**Payment before shipping.** The card is *authorized* at checkout: a hold on the customer's balance, no money moved. It is *captured* — the charge itself — once the order is confirmed, and only a paid order is shipped. A temporary provider failure is retried inside Payments; a refused capture cancels the order before anything leaves the warehouse. (Capturing close to fulfilment is common card practice; the rules vary by card network and region.)

**Cancellation** asks the module that knows. Fulfillment is asked to cancel the shipment and refuses once the carrier has the parcel — even if Orders has not heard yet — and the customer is pointed to a return. Otherwise the order is cancelled and a job gives back the stock and asks Payments to *release* the payment: Payments voids the hold if nothing was captured and refunds if something was, deciding from its own state when the job runs. An order still `placed` can have a capture that landed before Orders heard of it; asking Orders' own state would have voided nothing and left the customer charged. **Abandoned orders** — still unpaid 30 minutes after checkout — are cancelled by a scheduled business rule, the same way.

**Carrier reports arrive in any order.** The workers run in parallel and EventRail promises no ordering, so a delivery can be handled before the dispatch it follows. Orders' delivery subscriber then raises and is retried until the dispatch is recorded, rather than succeeding without effect and losing the delivery.

**Returns** end in a refund: the carrier brings the parcel back, Orders restocks it and commands a refund, and the order is refunded when Payments reports it. A refund the provider definitively refuses sets the order aside for a person rather than retrying forever.

## Errors, retries and idempotency

**At the boundary, the caller decides.** A checkout that fails tells its caller, and the caller retries. For that to be safe the operation must be idempotent: the checkout form carries a **checkout key**, and there is at most one order per key. A repeated checkout finds the order and returns it; one that finds none, because every earlier attempt was rejected, is a fresh attempt. A repeat never runs anything again: the order's follow-up was committed with the order, so there is nothing to resume.

**Work started at a boundary is staged with the data.** A web request that writes an order and must also start its follow-up has a dual write: the queue is a separate database, so enqueuing cannot join the order's transaction. Staging can. `FollowUpJob.stage_later_as` writes the job, in Active Job's own serialized form, to `platform_staged_jobs` in the same transaction as the order, and they commit or roll back together. After the commit the job is handed to the queue at once; if that fails, `Platform::StagedJobRelayJob`, running every second, hands it over shortly after. An accepted order always proceeds, whether or not the customer hears the answer. Handing a job over twice is harmless: it keeps its job ID, so it is the same command publishing the same event IDs. Only boundaries stage — inside a job, the job's own retry repeats a lost enqueue — and the staging table lives in the store of the data it commits with, so a module given its own database gets its own table while the queue keeps its own.

**Inside, EventRail keeps identities stable.** An event's ID is derived from the job publishing it, so a retried job publishes the same fact under the same ID and every subscriber recognises the repetition. The shop leans on this in three places:

- Commands and the follow-up are enqueued under IDs derived from their business key (`Platform::ApplicationJob.perform_later_as`), so repeating a command republishes its outcome under the same event ID.
- Every publisher reports its current state unconditionally rather than only when it made the change, so a job that crashed between its write and its publication publishes on its retry — under the same identity.
- Only a job derives identity: an event published from a web request, or from any code outside a job, gets a random ID. So a step started outside a job hands anything it must publish replay-stably to a job — cancellation's announcement comes from a job whose ID is derived from the order, and a repeated announcement carries the same event ID.
- A job that exhausts its retries reports the outcome inside `perform`, on its last attempt, not from a `retry_on` block: the block runs after EventRail's context has closed, and the outcome would drop out of the order's flow.

**Every reaction is idempotent** — a conditional state transition, or a unique index on the order and the kind of fact — because delivery is at least once. A handler repeated after an interruption takes every step its state calls for, not only the ones that follow a transition it made itself. And every handler an order depends on retries a failure on its own schedule, so one failed attempt never strands an order.

The patterns, in short: **compensate by your own attempt's reference**; **ask the module that owns a step for its state before undoing it**; **publish replay-stable facts from jobs**; **take the next step whenever the state calls for it**; **retry an unmet prerequisite rather than dropping the fact**.

**Lineage.** A checkout opens EventRail's context with a message ID derived from its key; every job that includes `EventRail::JobContext` carries it on, and every event records its correlation and causation. That is all the console needs to draw an order's tree. Jobs that *start* flows — the simulator's tick, the expiry scan — deliberately carry no context, like a web request; jobs that *continue* flows do.

## An event that changed shape

`OrderPlaced` version 1 carried the total as an integer `total_cents`. Version 2 carries a `Money` with its currency. Retyping a field breaks every reader, so it is a new version, not an edit:

1. Subscribers learned to read both — `subscribes_to Orders::Events::OrderPlaced, Orders::Events::OrderPlacedV1`.
2. The publisher switched to version 2.
3. Once no version 1 message can still be queued, the old class and the old branch can go.

The example stays between steps 2 and 3 on purpose. The queue refers to an event by type and version, never by class name, so the old class could be renamed `OrderPlacedV1` without breaking what was queued.

## A module that joined later

Loyalty was added after the rest of the shop. It took an engine, one `require_relative` in `config/application.rb`, and a `package.yml` depending on `Orders`' published events — and no existing module changed. It hears `OrderDelivered` and `OrderRefunded`, and when it fails, orders are still delivered. That is the property EventRail exists for: the code that announces a fact learns nothing about who listens.

## Anatomy of a module

```
engines/orders/
  lib/orders/engine.rb             isolate_namespace Orders; requires the engines it builds on
  bin/rails                        the module's own Rails command: generators write into the module
  package.yml                      its dependencies, enforced by packwerk
  app/public/orders/api.rb         Orders::Api: the synchronous public API, returning plain values
  app/public/orders/events/        Orders::Events: published events, a package of their own
    package.yml                    dependencies: [] -- an event can never reach into Orders
  app/models/orders/, app/jobs/orders/, db/migrate/, test/
```

- **The public API returns `Data` values, never records.** Packwerk sees only constant references; a record returned across a boundary would hand out its whole association graph without a violation being reported.
- **Published events are a separate package.** A module that only reacts to Orders depends on `engines/orders/app/public/orders/events` alone: it can subscribe, and cannot call Orders' API or read its tables. Because the events package depends on nothing, two modules can hear each other's events without a package cycle. `config.event_rail.roots << "app/public"` is what makes EventRail discover every module's published events at boot.
- **An internal event** — one only its own module hears — would sit directly in the namespace, outside `app/public`, and packwerk would report any other module referencing it.

Not every module needs to be an engine. **An engine** when it needs Rails: models, migrations, jobs, routes. **A plain package** — a folder with a `package.yml` on an eager-load path — when it is plain Ruby for this application. **A local gem** when it should work without this application; packwerk then sees only what the gem references, not who references it, and it does not reload in development.

## Boundaries, enforced, not described

```sh
bin/packwerk validate   # the dependency graph has no cycle
bin/packwerk check      # no module references another's internals or an undeclared module
```

Both run in CI. `test/boundaries` plants rule-breaking files into a copy of the application — a private model reached from outside, an undeclared dependency, a transitive one, an upward call, a published event reaching into its module, another module subscribing to an internal event, a declared cycle — and asserts each is caught. The rules apply to tests too.

## Alternatives we tried and rejected

- **packs-rails with automatic_namespaces**, or attaching a namespace to a folder by hand, to avoid repeating the module name in `app/models/orders/`. Both work with packwerk and EventRail, and both break Rails' generators, which then write files where the module does not look. One repeated folder was cheaper.
- **Events inside the module package.** Two modules reacting to each other's events then form a package cycle, and a subscriber gains the publisher's whole API.
- **One shared package for every event.** No cycles, but ownership becomes a folder convention and every team edits one package. The reference modular monoliths we studied give each module its own contracts package instead, which is what `app/public/<module>/events` is.
- **Jobs and business data in one database**, to enqueue atomically with the commit. It couples job storage to business storage — the opposite of where per-module storage would go. A staging table and a relay give the same atomicity and keep the queue separate.
- **Letting the caller's retry recover a lost enqueue** (the first version). It is consistent — the caller is told "placed" only after the hand-off — but a repeat had to re-enqueue whenever the order still looked unstarted, which it also did on every double submission: the whole flow ran twice, every step a no-op the second time.
- **An idempotency-key table with stored responses and a 409 for a concurrent duplicate**, as payment APIs do. With the follow-up committed alongside the order, the order row and its unique key are idempotency enough.

## Tests

```sh
bin/rails test test engines/*/test   # modules, whole flows, boundary probes, the console
bin/rails test:system                # only the console, in headless Chrome
bin/ci                               # everything CI runs
```

Module tests live with their module in `engines/<module>/test`. Each engine has its own `bin/rails`, so `bin/rails generate model Refund` run in `engines/payments` writes `Payments::Refund` and a `payments_refunds` migration into Payments. System tests drive headless Chrome through [Cuprite](https://github.com/rubycdp/cuprite); set `BROWSER_PATH` if Chrome is not on your `PATH`. Whole-flow tests in `test/flows` work off the queue one job at a time, as a worker does, and check what every module ended up with through its public API. The `example` job in the gem's CI runs all of it on every pull request, against the gem's current source.
