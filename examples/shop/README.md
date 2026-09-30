# Shop: a modular Rails application built with EventRail

A small online shop — carts, placing and confirming orders, payment, shipping, cancellation, returns, loyalty points and customer notifications — split into modules inside one Rails application. It exists to show two things at once:

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
| **New cart** | Fill a cart by hand and place it. *Place it twice at once* places the same cart twice, concurrently — and gets one order |
| **Architecture** | The module graph read from `package.yml`, and which subscribers were seen reacting to which events |
| **Jobs** | Mission Control: the queue itself. Every subscriber delivery is an ordinary job, with its own queue and retries |

Things to try:

1. **Start the simulator** at 60 orders a minute and open an order: `orders.order_placed`, the capture, the shipment, delivery, points.
2. **Set "payment provider times out" to 40%.** Open a new order's flow: the capture job fails an attempt or two and then succeeds. Nothing else in the shop noticed.
3. **Break Loyalty** — make `Loyalty::AwardPointsJob` fail its next 5 runs. Orders keep being delivered; Loyalty retries on its own schedule and catches up. Its failures are visible in its own branch of the tree, and in Jobs.
4. **Set "capture refused" to 100%.** Orders are placed and confirmed, then cancelled: stock released, card hold voided, customer notified — and nothing ships.
5. **Request the cancellation of a paid order** from its page before it ships, or **return a delivered one**: the refund appears as a new branch of the same flow. A cancellation requested after the carrier collected the parcel is refused, and the page says so.

## The modules

Each module is a Rails engine under `engines/`, with one namespace named after it and the standard engine layout, so Rails' generators keep working.

| Module | Owns | Calls | Publishes (`<Module>::Events`) | Listens to |
| --- | --- | --- | --- | --- |
| `Platform` | base classes, demonstration fault settings | — | — | — |
| `Catalog` | products, prices, stock, reservations | — | — | — |
| `Payments` | authorizations, captures, voids, refunds; a fake gateway | — | `PaymentCaptured`, `CaptureFailed`, `AuthorizationVoided`, `RefundIssued`, `RefundFailed` | — |
| `Fulfillment` | shipments and returns; a fake carrier | — | `ShipmentDispatched`, `ShipmentDelivered`, `ReturnReceived` | — |
| `Orders` | carts, orders and their whole lifecycle, returns | Catalog, Payments, Fulfillment | `OrderPlaced` (v2, v1 kept), `OrderShipped`, `OrderDelivered`, `OrderCancelled`, `OrderRefunded` | Payments, Fulfillment |
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

One question decides between a call, a request and an event: **if nobody reacted, would the publisher's own process be incomplete?**

- **Yes** — then the step is the publisher's to cause. A **call that decides now** when it cannot continue without the answer: when it returns, the outcome is final, and a refusal is raised. A **request** — an API method named `request_*` that records it, or enqueues the module's own job, and returns — when the work is slow, unreliable or behind an external provider; its outcome arrives later as an event, or the request waits in the failed jobs to be replayed.
- **No** — then it is someone else's business, and it is an **event**.

Every interaction between two modules in this application:

| Interaction | Mechanism | Why |
| --- | --- | --- |
| `Catalog::Api.product` | query | a cart takes only products the shop sells |
| `Catalog::Api.quote` | query | placing an order freezes the prices it was placed at |
| `Catalog::Api.reserve` | decides now | confirming an order must know now whether the stock is there |
| `Catalog::Api.release` | decides now | giving back Orders' own reservation, for a cancellation |
| `Catalog::Api.ship` | decides now | the reserved stock leaves the warehouse when the parcel is dispatched |
| `Catalog::Api.restock` | decides now | a returned parcel goes back on the shelf |
| `Catalog::Api.products` | query | the simulator picks what to buy |
| `Catalog::Api.receive_stock` | decides now | the simulated supplier refills a low shelf |
| `Payments::Api.authorize` | decides now, calls the provider | confirming an order must know now whether the card was declined |
| `Payments::Api.request_capture` | request | the provider is slow and flaky; Orders waits for the outcome event |
| `Payments::Api.request_release` | request | a cancellation gives back whatever the payment holds; Payments decides between void and refund, because only Payments knows whether a capture has landed |
| `Payments::Api.request_refund` | request | giving money back for a returned parcel |
| `Fulfillment::Api.request_shipment` | request | the carrier works on its own schedule |
| `Fulfillment::Api.cancel_shipment` | decides now | a cancellation must know whether the parcel has left, and only Fulfillment knows |
| `Fulfillment::Api.request_return_pickup` | request | the carrier brings the parcel back when it does |
| `Orders::Api.open_cart` | decides now | the simulator is a client filling a cart |
| `Orders::Api.place_order` | request | the simulator places the cart; confirming it follows |
| `Orders::Api.request_cancellation` | request | a simulated customer changing their mind; Fulfillment decides, a moment later |
| `Orders::Api.request_return` | request | a simulated customer sending an order back |
| `Orders::Api.recent` | query | the simulator picks an order to cancel or return |
| `subscribes_to Payments::Events::PaymentCaptured` | event (Orders) | the outcome of Orders' capture request: pay, then ship |
| `subscribes_to Payments::Events::CaptureFailed` | event (Orders) | the outcome of Orders' capture request: cancel |
| `subscribes_to Payments::Events::RefundIssued` | event (Orders) | the outcome of Orders' refund request: complete the return |
| `subscribes_to Payments::Events::RefundFailed` | event (Orders) | the outcome of Orders' refund request: set the order aside |
| `subscribes_to Fulfillment::Events::ShipmentDispatched` | event (Orders) | Fulfillment cannot call upward; Orders hears the carrier's progress |
| `subscribes_to Fulfillment::Events::ShipmentDelivered` | event (Orders) | as above |
| `subscribes_to Fulfillment::Events::ReturnReceived` | event (Orders) | as above: restock and refund |
| `subscribes_to Orders::Events::OrderPlaced` | event (Notifications) | Orders is complete without anyone hearing it |
| `subscribes_to Orders::Events::OrderPlacedV1` | event (Notifications) | version 1 messages still in the queue (see [Versioning](#an-event-that-changed-shape)) |
| `subscribes_to Orders::Events::OrderShipped` | event (Notifications) | as above |
| `subscribes_to Orders::Events::OrderDelivered` | event (Notifications, Loyalty) | a Loyalty outage must never delay a delivery |
| `subscribes_to Orders::Events::OrderCancelled` | event (Notifications) | as above |
| `subscribes_to Orders::Events::OrderRefunded` | event (Notifications, Loyalty) | as above |

Inside a module, work with one known handler is a plain job, staged by name, not an event: confirming an order, carrying out a cancellation, the carrier's scheduled steps, the capture itself, the deadline sweep, the simulator's tick. An event would add indirection and nothing else. For the same reason this shop has **no internal events**: none passed the question above, and a plain job does the same work with less machinery.

### Anti-patterns this design avoids

- **The disguised command.** "Payments captures the payment when it hears `OrderPlaced`" reads like decoupling. It hides a required step of the order's own process inside another module's subscriber — if that subscriber is removed or broken, orders are silently never charged — and it teaches Payments what an order is. Getting paid is Orders' job, so Orders *commands* it and *listens* for the outcome.
- **Questions through events.** `PriceRequested` answered by `PriceProvided` is request/reply rebuilt on a queue. When you need an answer, call.
- **Calling the periphery synchronously.** Awarding points or notifying the customer inside checkout would turn a Loyalty or Notifications outage into a checkout outage.
- **An orchestration layer for flows that have an owner.** Return, refund and close belong to Orders, which already depends on Payments and Fulfillment. A separate processes layer earns its place only for a flow that no module owns.

## The flows

**Orders is a set of nouns with verbs** (`engines/orders/app/models/orders/`). A `Cart` is placed as an `Order`; an order is confirmed, paid, shipped, delivered, cancelled; a `Return` is received and refunded. Each verb lives on the noun it acts on; jobs and the API call them in one line. `Order` includes one concern per trait — `Confirmable`, `Payable`, `Shippable`, `Cancellable`, `Returnable` — and states the rules that span them, `cancellable?` and `returnable?`, once, on the order itself.

**An order has three states and many facts.** Its lifecycle is `placed`, `confirmed`, `cancelled`. Everything after confirming is a fact with its time — `paid_at`, `shipped_at`, `delivered_at`, `cancellation_requested_at`, `cancellation_refused_at` — because payment and shipping have states of their own, in Payments and Fulfillment, and the order keeps only what it acts on. What a person sees — *placed, confirmed, paid, shipped, delivered, returning, refunded, cancelled, needs attention* — is its **status**, derived from the state, the facts and its return.

**Placing and confirming** (`Orders::Cart#place_order`, `Orders::Order::Confirmable`):

```
request: open the cart → place it: price it, record the placed order with its confirmation staged → answer
job:     announce OrderPlaced → hold the stock → authorize the card → confirmed → request the capture
```

A cart refuses what it can tell at once — a quantity that is not a whole number, a product the shop does not sell — and an empty cart cannot be placed. Placing records the order, priced as the products are now, and nothing outside Orders changes. Confirming happens in a job, under the order's own reference: it holds the stock and authorizes the card, then moves the order to confirmed and requests the capture. Out of stock, or a declined card, requests the order's cancellation with the reason. Every step is safe to repeat on the reference, so a retry, or a crash at any point, runs the job again to the same end. The order's page shows the order being confirmed, then confirmed or cancelled with the reason, usually within a second. That is the trade-off: the customer hears "declined" a moment after placing, rather than in the response, as with the many real shops that confirm an order by email.

**Payment before shipping.** The card is *authorized* when the order is confirmed: a hold on the customer's balance, no money moved. It is *captured* — the charge itself — right after, and only a paid order is shipped. A temporary provider failure is retried inside Payments; a refused capture cancels the order before anything leaves the warehouse. (Capturing close to fulfilment is common card practice; the rules vary by card network and region.)

**Cancellation is a request** (`Orders::Order::Cancellable`), as in most real shops. Anyone may ask — the customer, a refused capture, a deadline — and the request is recorded at once, under the order's lock. Whether it can still happen is Fulfillment's to say, in a job, because only Fulfillment knows whether the carrier has the parcel — even before Orders has heard. If it has, the cancellation is refused and the order page points to a return. Otherwise the order is cancelled, and every run of the job gives back the stock, asks Payments to *release* the payment, and announces `OrderCancelled`. Payments voids the hold if nothing was captured and refunds if something was, deciding from its own state when it runs: an order not yet marked paid can have a capture that landed before Orders heard of it.

**Deadlines, not retry counts, give up on an order.** Retrying is infrastructure: every job retries a temporary failure until it succeeds, or ends in the failed jobs to be replayed once the cause is fixed. Giving up is a business decision, taken by `Orders::DeadlineSweepJob` every minute: an order placed but not confirmed within two minutes, and an order confirmed but not paid within thirty, has its cancellation requested with the reason. A job still working on such an order finds it cancelled on its next run and does nothing — or, if it was confirming, gives back what it had just taken.

**Carrier reports arrive in any order.** The workers run in parallel and EventRail promises no ordering, so a delivery can be handled before the dispatch it follows. Orders' delivery subscriber then raises and is retried until the dispatch is recorded, rather than succeeding without effect and losing the delivery.

**Returns** are an aggregate of their own (`Orders::Return`). The order checks its own rules — delivered, within 14 days, not already coming back — under its lock, and creates the return; from then on the return lives its own life: the carrier brings the parcel back, Orders restocks it and requests a refund, and the return is refunded when Payments reports it. A refund the provider definitively refuses sets the return aside for a person rather than retrying forever.

## Errors, retries and idempotency

**At a boundary, record the decision and stage what follows.** Every write that starts at a boundary follows this one rule: placing an order, a cancellation request, a return request, the deadline sweep. The domain method writes its decision and the job that carries it out in one transaction, and returns; the job does everything that touches another module, and retries until the shop matches the decision. Nothing that could need undoing happens inside a request, so a request that fails has changed nothing but its own, rolled-back transaction.

**A cart gives at most one order.** The order holds its cart's ID under a unique index, so placing a cart again — a double click, a retry after a timeout — returns that order, whatever its state, and runs nothing again. Two placements at once meet at the index, and the one that loses has touched nothing. A customer trying again after a cancellation fills a new cart.

**Work started by a domain method is staged with its data.** Placing an order writes the order and must also start confirming it: a dual write, since the queue is a separate database and enqueuing cannot join the order's transaction. Staging can. `ConfirmJob.stage` writes the job, in Active Job's own serialized form, to `platform_staged_jobs` in the same transaction as the order, and they commit or roll back together. `Platform::StagedJob` is also the shop's EventRail stager (`config.event_rail.stager`), so an event staged with `EventRail.stage` has its subscriber jobs written to the same table and handed over the same way. After the commit the job is handed to the queue at once; if that fails, `Platform::StagedJobRelayJob`, running every second, hands it over shortly after. A placed order is always confirmed or cancelled, whether or not the customer hears the answer. Handing a job over twice is harmless: it is the same command, and its events carry the same IDs because each declares its identity. A domain method stages wherever it runs — in a job too, where it costs a row and is never wrong — and the staging table must live in the store of the data it commits with. Every module shares one database here, so there is one table; a module moved to a database of its own would need a staging table there, a stager that routes each staging to the store whose transaction is open, and the relay taught to use it, while the queue keeps its own database. Inside a job, anything enqueued directly goes through `perform_later!`, which raises when the queue refuses it, so the job's own retry sends it again; Active Job's `perform_later` returns `false` instead, and the job would succeed having lost it.

**Every event declares what it is about.** Each event class names the attributes that identify its fact — `identity_by :order_id` for an order's `OrderPlaced`, `identity_by :reference` for a payment's `PaymentCaptured` — and EventRail derives the event's ID from them. The same fact has one ID however often, and from whichever job, it is published, so every subscriber recognises a repetition. The shop leans on this:

- Every publisher reports its current state unconditionally rather than only when it made the change, so a job that crashed between its write and its publication publishes on its retry — under the same identity. A command repeated by two callers does the same.
- A request never publishes. It stages the job that does, because only a job retries a publication that failed: a cancellation's announcement comes from `Orders::CancelJob`.

**Every reaction is idempotent** — a conditional update of the row, or a unique index on the order and the kind of fact — because delivery is at least once. A handler repeated after an interruption takes every step its state calls for, not only the ones that follow a change it made itself. And every job retries under one policy, chosen by the failure's category rather than declared job by job, so one failed attempt never strands an order. A job whose worker dies mid-run is failed by Solid Queue outside any `retry_on`; `Platform::RetryInterruptedJobsJob` runs such jobs again every minute. A Payments command that gives up gives up its claim on the payment with it, so the next command can reach the provider.

The patterns, in short: **record the decision and stage what follows**; **ask the module that owns a step for its state before undoing it**; **identify each event by its fact, and publish what must happen from jobs**; **take the next step whenever the state calls for it**; **retry an unmet prerequisite rather than dropping the fact**; **let deadlines, not retries, give up**.

**Lineage.** Placing a cart opens EventRail's context with a message ID derived from the cart; every job that includes `EventRail::JobContext` carries it on, and every event records its correlation and causation. That is all the console needs to draw an order's tree. Jobs that *start* flows — the simulator's tick, the deadline sweep — deliberately carry no context, like a web request; a cancellation or a return they request joins the order's own flow (`Orders::Flow`), and so does one requested from the console.

**Every error says what a caller should do.** A module's error is named for what happened — `NotCancellable`, `Declined` — lives in the module's namespace, one public file each in `app/public/<module>/`, and includes one of Platform's categories, named after gRPC's status codes: `FailedPrecondition`, `Unavailable`, `Aborted` and the rest (`Platform::ErrorCategory`). Only infrastructure reads the category. `Platform::ApplicationJob` holds the shop's one retry policy: a temporary failure is retried with backoff, a lost race quickly, an expected failure nobody handled fails at once, a job whose own subject is gone is discarded, and an error with no category — a bug, or something nobody has classified — is retried and then left in the failed-jobs list. `Platform::ErrorSubscriber` is the one place errors are reported from: it counts expected failures rather than reporting them, and reports everything else with the flow it happened in.

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
  app/public/orders/api.rb         Orders::Api: the public API, returning plain values
  app/public/orders/*.rb           Orders' public errors, one file each
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

Both run in CI. `test/boundaries` plants rule-breaking files into a copy of the application — a private model reached from outside, an undeclared dependency, a transitive one, an upward call, a published event reaching into its module, another module subscribing to an internal event, a declared cycle — and asserts each is caught. The rules apply to tests too. `test/boundaries` also checks the design rules packwerk cannot see: every error has a category, no job declares a retry policy of its own, every event lives in its module's published events, and every domain job's `perform` is one line.

## Alternatives we tried and rejected

- **packs-rails with automatic_namespaces**, or attaching a namespace to a folder by hand, to avoid repeating the module name in `app/models/orders/`. Both work with packwerk and EventRail, and both break Rails' generators, which then write files where the module does not look. One repeated folder was cheaper.
- **Events inside the module package.** Two modules reacting to each other's events then form a package cycle, and a subscriber gains the publisher's whole API.
- **One shared package for every event.** No cycles, but ownership becomes a folder convention and every team edits one package. The reference modular monoliths we studied give each module its own contracts package instead, which is what `app/public/<module>/events` is.
- **Jobs and business data in one database**, to enqueue atomically with the commit. It couples job storage to business storage — the opposite of where per-module storage would go. A staging table and a relay give the same atomicity and keep the queue separate.
- **Letting the caller's retry recover a lost enqueue** (the first version). It is consistent — the caller is told "placed" only after the hand-off — but a repeat had to re-enqueue whenever the order still looked unstarted, which it also did on every double submission: the whole flow ran twice, every step a no-op the second time.
- **A checkout key**, new each time the form was shown, with one order per key (the previous version). It worked, but it was machinery the domain did not have: a real shop has a cart, and a cart that becomes one order is idempotency for free.
- **An idempotency-key table with stored responses and a 409 for a concurrent duplicate**, as payment APIs do. With the order recorded before anything else happens, the cart's unique order is idempotency enough.
- **Counting retries to give up** (the previous version): a placement rejected after three unavailable authorizations, a capture refused after five, a notice dropped after three. A retry count means nothing to the business and resets whenever a new job carries the same work. Deadlines say what the business means.
- **Cancelling on the spot** (the previous version): the request asked Fulfillment to stop the shipment and then recorded the cancellation, so a crash between the two left a stopped shipment on an order still paid, with nothing to repair it. A cancellation request, carried out in a job, is also what real shops offer.
- **Deciding checkout within the request** (the first version). The customer heard "declined" in the response, but every undo — releasing the stock, voiding the hold — ran in a request that could not repeat it: a failed release left stock held for good, a void the queue refused left the card's hold for days, and a crash left both. And each attempt under a key needed a reference of its own, so that a late undo could not touch a retry's. Recording the order first and placing it in a job removed both.

## Tests

```sh
bin/rails test test engines/*/test   # modules, whole flows, boundary probes, the console
bin/rails test:system                # only the console, in headless Chrome
bin/ci                               # everything CI runs
```

Module tests live with their module in `engines/<module>/test`. Each engine has its own `bin/rails`, so `bin/rails generate model Refund` run in `engines/payments` writes `Payments::Refund` and a `payments_refunds` migration into Payments. System tests drive headless Chrome through [Cuprite](https://github.com/rubycdp/cuprite); set `BROWSER_PATH` if Chrome is not on your `PATH`. Whole-flow tests in `test/flows` work off the queue one job at a time, as a worker does, and check what every module ended up with through its public API. The `example` job in the gem's CI runs all of it on every pull request, against the gem's current source.
