# Shop: a modular Rails application built with EventRail

A small online shop — carts, placing and confirming orders, payment, shipping, cancellation, returns, loyalty points and customer notifications — split into modules inside one Rails application. It exists to show two things at once:

- **How modules in one Rails application talk to each other.** A method call where the caller needs the answer now. An asynchronous command where the caller owns a step but need not wait for it. An event only for a fact the publisher would be complete without anyone hearing. And why each interaction below is the one it is.
- **What EventRail adds when an event is the right tool.** Each subscriber is an ordinary Active Job with its own retries. An event keeps its identity across retries and redeliveries. Every flow carries a correlation you can follow. And a module can join by subscribing, with no existing module changing.

It is not a real shop — no sign-in, no real payment provider, no storefront — and it is not event sourcing. Everything that would hide the point was left out.

## Run it

```sh
cd examples/shop
bin/setup   # installs gems, creates both databases, seeds the products, starts the server
```

After the first time, `bin/dev` starts it again. Requires Ruby 3.3 or newer; the databases are SQLite files in `storage/`.

`bin/setup` is safe to run again after pulling changes: it keeps your data and applies what is new. To start over with a fresh shop instead — its data discarded, both databases rebuilt from `db/schema.rb` and seeded — run `bin/setup --reset`.

`bin/dev` is the only process: Solid Queue's dispatcher, scheduler and workers run inside Puma, so jobs and EventRail subscribers run as soon as the server does. The terminal shows web requests; jobs log to `log/jobs.log` (`tail -f log/jobs.log`), because the staged-jobs relay runs every second. Set `RAILS_LOG_LEVEL=debug` to see every SQL query.

## Try it

Orders has a small JSON API, mounted by the host at `/`. Open a cart, place it, and read the order back:

```sh
curl -s localhost:3000/carts -H 'Content-Type: application/json' -d '{
  "customer_id": "cus_1", "customer_name": "Ada Lovelace", "customer_email": "ada@example.com",
  "shipping_address": "1 Example Street, London",
  "items": [ { "sku": "MUG-STONE", "quantity": 2 }, { "sku": "TEA-GREEN", "quantity": 1 } ]
}'
curl -s -X POST localhost:3000/carts/1/order          # placed; posting again returns the same order
curl -s localhost:3000/orders/1                       # confirmed, paid, shipped, delivered, over a few seconds
curl -s -X POST localhost:3000/orders/1/return        # once delivered
curl -s -X POST localhost:3000/orders/1/cancellation  # or, on another order, before it ships
```

| Request | Answer |
| --- | --- |
| `POST /carts` | `201` with the cart; `422` with every problem in the request: no items, a customer detail missing, a quantity that is not a whole number above zero, a product the shop does not sell or lists twice |
| `POST /carts/:id/order` | `201` with the order, placed. Posting again returns the same order |
| `GET /orders/:id` | the order and its status |
| `POST /orders/:id/cancellation` | `202`: the request is recorded and carried out a moment later; `409` once the order has shipped |
| `POST /orders/:id/return` | `202`: the carrier brings the parcel back, then the order is refunded; `409` outside the return window |

Each controller makes one call to the model and renders. The JSON is written out field by field in `Orders::ApplicationController`, a contract of its own rather than a record's attributes.

Every error is answered in one shape, problem details ([RFC 9457](https://www.rfc-editor.org/rfc/rfc9457.html)), with the status its category calls for, so no action rescues anything (`Platform::ApplicationController`). Refused input lists every problem at once, each with a JSON Pointer into the request, so a form can show it beside its field:

```json
{
  "title": "Unprocessable Content", "status": 422, "code": "invalid_input",
  "detail": "customer_email can't be blank; items[1].sku is not a product the shop sells",
  "errors": [
    { "pointer": "/customer_email", "code": "blank", "detail": "can't be blank" },
    { "pointer": "/items/1/sku", "code": "unknown_product", "detail": "is not a product the shop sells" }
  ]
}
```

The request's fields are the cart's own, and its items are nested records (`accepts_nested_attributes_for`), so the cart's Active Record validations check the whole request at once, each item's errors numbered by its position. `Cart.open` raises them as one `Platform::InvalidInput`, the error any module raises for input it refuses, whoever called it. An unknown route, or a bug, gets the same shape from `Platform::ExceptionsApp`, with no detail.

Everything after each answer runs in jobs; `tail -f log/jobs.log` shows them. The faults the shop is built to survive — a provider timing out, a capture refused, a subscriber failing every attempt — are injected by the flow tests in `test/flows`.

## The modules

Each module is a Rails engine under `engines/`, with one namespace named after it and the standard engine layout, so Rails' generators keep working.

| Module | Owns | Calls | Publishes (`<Module>::Events`) | Listens to |
| --- | --- | --- | --- | --- |
| `Platform` | base classes, the staged-jobs table | — | — | — |
| `Catalog` | products, prices, stock, reservations | — | — | — |
| `Payments` | authorizations, captures, voids, refunds; the private gateway seam (`Payments::Gateway`) and a fake provider | — | `PaymentCaptured`, `CaptureFailed`, `AuthorizationVoided`, `RefundIssued`, `RefundFailed` | — |
| `Fulfillment` | shipments and returns; the private carrier seam (`Fulfillment::Carrier`) and a fake carrier | — | `ShipmentDispatched`, `ShipmentDelivered`, `ReturnReceived` | — |
| `Orders` | carts, orders and their whole lifecycle, returns | Catalog, Payments, Fulfillment | `OrderPlaced` (v2, v1 kept), `OrderShipped`, `OrderDelivered`, `OrderCancelled`, `OrderRefunded` | Payments, Fulfillment |
| `Notifications` | customer notifications (recorded, not emailed) | — | — | Orders |
| `Loyalty` | a points ledger | — | — | Orders |

The host application boots the modules and mounts Orders' routes; it has no code of its own.

```
    Notifications      Loyalty
          ╎               ╎
          ╎╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌▼
                       Orders
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
       Payments     Fulfillment      Catalog
          └──────────────┴──────┬───────┘
                                ▼
                             Platform

   ───►  may call (and hear)          ╌╌╌  hears published events only
```

Calls point one way: down. Catalog, Payments and Fulfillment know nothing above them — Payments moves money *for a reference* and Fulfillment ships *to a reference*; neither knows what an order is. Notifications and Loyalty depend only on Orders' published events, and nothing depends on them. Packwerk enforces all of it in CI (see [Boundaries](#boundaries-enforced-not-described)).

**Outside systems sit behind a seam.** Payments talks to a payment provider only through `Payments::Gateway`, and Fulfillment to a carrier only through `Fulfillment::Carrier`. Each environment chooses the adapter in `config/environments/*.rb` (`config.payments.gateway = :fake`), as it chooses Active Job's queue adapter; the module builds it on first use, and the boot fails when the choice is missing, so a shop can't take fake payments by accident. The seams and their adapters are private to their modules, in `app/adapters/<module>/`; other modules' tests plug in a scripted adapter through the module's test support (`Payments::TestSupport.scripted_gateway(capture: [ :refuse ])`).

Catalog holds two things a larger shop splits: what it sells (products and prices) and what it has (stock and reservations). A `Catalog::Reservation` is stock set aside under a caller's reference, with a line per product; a hold locks the products it takes from, and shipping takes the stock off the shelf in the same transaction that marks the reservation shipped, because "never promise more than is on the shelf" needs both. That is why the two stay together: a split would move `on_hand` and the reservations into an Inventory module as one, leaving names and prices behind.

## What goes where

One question decides between a call, a request and an event: **if nobody reacted, would the publisher's own process be incomplete?**

- **Yes** — then the step is the publisher's to cause. A **call that decides now** when it cannot continue without the answer: when it returns, the outcome is final, and a refusal is raised. A **request** — an API method named `request_*` that records it, or enqueues the module's own job, and returns — when the work is slow, unreliable or behind an external provider; its outcome arrives later as an event, or the request waits in the failed jobs to be replayed.
- **No** — then it is someone else's business, and it is an **event**.

Every interaction between two modules in this application (`test/docs/readme_guide_test.rb` fails when one is missing from this table):

| Interaction | Mechanism | Why |
| --- | --- | --- |
| `Catalog::Api.products` | query | a cart takes only products the shop sells; one question for all its items |
| `Catalog::Api.quote` | query | placing an order freezes the prices it was placed at |
| `Catalog::Api.reserve` | decides now | confirming an order must know now whether the stock is there |
| `Catalog::Api.release` | decides now | giving back Orders' own reservation, for a cancellation |
| `Catalog::Api.ship` | decides now | the reserved stock leaves the warehouse when the parcel is dispatched |
| `Catalog::Api.restock` | decides now | a returned parcel goes back on the shelf |
| `Payments::Api.authorize` | decides now, calls the provider | confirming an order must know now whether the card was declined |
| `Payments::Api.request_capture` | request | the provider is slow and flaky; Orders waits for the outcome event |
| `Payments::Api.request_release` | request | a cancellation or a returned parcel gives back whatever the payment holds; Payments decides between void and refund, because only Payments knows whether a capture has landed |
| `Fulfillment::Api.request_shipment` | request | the carrier works on its own schedule |
| `Fulfillment::Api.cancel_shipment` | decides now | a cancellation must know whether the parcel has left, and only Fulfillment knows |
| `Fulfillment::Api.request_return_pickup` | request | the carrier brings the parcel back when it does |
| `subscribes_to Payments::Events::PaymentCaptured` | event (Orders) | the outcome of Orders' capture request: pay, then ship |
| `subscribes_to Payments::Events::CaptureFailed` | event (Orders) | the outcome of Orders' capture request: cancel |
| `subscribes_to Payments::Events::RefundIssued` | event (Orders) | the outcome of a return's release request: complete the return |
| `subscribes_to Payments::Events::RefundFailed` | event (Orders, twice) | the outcome of a release request, final: the return's subscriber and the cancellation's each look for their own record, and the one that finds it sets it aside for a person |
| `subscribes_to Fulfillment::Events::ShipmentDispatched` | event (Orders) | Fulfillment cannot call upward; Orders hears the carrier's progress |
| `subscribes_to Fulfillment::Events::ShipmentDelivered` | event (Orders) | as above |
| `subscribes_to Fulfillment::Events::ReturnReceived` | event (Orders) | as above: restock and refund |
| `subscribes_to Orders::Events::OrderPlaced` | event (Notifications) | Orders is complete without anyone hearing it |
| `subscribes_to Orders::Events::OrderPlacedV1` | event (Notifications) | version 1 messages still in the queue (see [Versioning](#an-event-that-changed-shape)) |
| `subscribes_to Orders::Events::OrderShipped` | event (Notifications) | as above |
| `subscribes_to Orders::Events::OrderDelivered` | event (Notifications, Loyalty) | a Loyalty outage must never delay a delivery |
| `subscribes_to Orders::Events::OrderCancelled` | event (Notifications) | as above |
| `subscribes_to Orders::Events::OrderRefunded` | event (Notifications, Loyalty) | as above |

Inside a module, work with one known handler is a plain job, staged by name, not an event: confirming an order, carrying out a cancellation, the carrier's scheduled steps, the capture itself, the deadline sweep. An event would add indirection and nothing else. A side effect the process doesn't need is different: it is a subscriber, so adding one never changes the process. It subscribes to the public event when other modules care about the fact, and to an **internal event** — one only its own module hears — when none does. The shop has no internal events because none of its reactions is such a side effect yet; one that may be lost, such as analytics, would be instrumented with `ActiveSupport::Notifications` or `Rails.event` rather than delivered as a job.

### Anti-patterns this design avoids

- **The disguised command.** "Payments captures the payment when it hears `OrderPlaced`" reads like decoupling. It hides a required step of the order's own process inside another module's subscriber — if that subscriber is removed or broken, orders are silently never charged — and it teaches Payments what an order is. Getting paid is Orders' job, so Orders *commands* it and *listens* for the outcome.
- **Questions through events.** `PriceRequested` answered by `PriceProvided` is request/reply rebuilt on a queue. When you need an answer, call.
- **Calling the periphery synchronously.** Awarding points or notifying the customer inside checkout would turn a Loyalty or Notifications outage into a checkout outage.
- **An orchestration layer for flows that have an owner.** Return, refund and close belong to Orders, which already depends on Payments and Fulfillment. A separate processes layer earns its place only for a flow that no module owns.

## The flows

**Orders is a set of nouns with verbs** (`engines/orders/app/models/orders/`). A `Cart` is placed as an `Order`; an order is confirmed, paid, shipped, delivered, cancelled; a `Return` is received and refunded. Each verb lives on the noun it acts on; jobs and controllers call them in one line. `Order` includes one concern per trait — `Confirmable`, `Payable`, `Shippable`, `Expirable`, `Cancellable`, `Returnable`. A trait's verbs, predicates and constants live in its concern, whatever state they read; `order.rb` keeps the order's identity, its factory, the `status` that combines every trait, and the glue several traits share.

**An order has three states and many facts.** Its lifecycle is `placed`, `confirmed`, `cancelled`. Everything after confirming is a fact with its time — `paid_at`, `shipped_at`, `delivered_at`, `cancellation_requested_at`, `cancellation_refused_at` — because payment and shipping have states of their own, in Payments and Fulfillment, and the order keeps only what it acts on. What a person sees — *placed, confirmed, paid, shipped, delivered, returning, refunded, cancelled, needs attention* — is its **status**, derived from the state, the facts and its return.

**The whole life of an order.** Orders drives it; each step that needs another module ends with a request, and the next step starts when that module's answer arrives as an event (`⇢`). Every request verb names its answers in a comment, so the chain can be followed from either end.

```
place            the order and OrderPlaced, with confirm_later staging ConfirmJob
ConfirmJob       hold the stock, authorize the card → confirmed → request the capture
                 out of stock or declined → request the cancellation
⇢ PaymentCaptured     mark_paid → request the shipment
⇢ CaptureFailed       request the cancellation
⇢ ShipmentDispatched  mark_shipped → ship the stock; OrderShipped
⇢ ShipmentDelivered   mark_delivered; OrderDelivered
cancellation     until dispatch: CancelJob cancels the shipment, cancels the order (OrderCancelled),
                 releases the stock and the payment ⇢ RefundFailed sets the order aside
return           within 14 days of delivery: pickup ⇢ ReturnReceived → restock, release the payment
                 ⇢ RefundIssued → refunded (OrderRefunded), or RefundFailed → set aside
deadlines        DeadlineSweepJob requests the cancellation of an order not confirmed or not paid in time
```

**Placing and confirming** (`Orders::Cart#place_order`, `Orders::Order::Confirmable`):

```
request: open the cart → place it: price it, record the placed order with OrderPlaced and its confirmation staged → answer
job:     hold the stock → authorize the card → confirmed → request the capture
```

A cart refuses what it can tell at once — a quantity that is not a whole number above zero, a product the shop does not sell, no items at all — so every cart opened can be placed. Placing records the order, priced as the products are now, and nothing outside Orders changes. Confirming happens in a job, under the order's own reference: it holds the stock and authorizes the card, then moves the order to confirmed and requests the capture. Out of stock, or a declined card, requests the order's cancellation with the reason. Every step is safe to repeat on the reference, so a retry, or a crash at any point, runs the job again to the same end. Read back, the order shows as being confirmed, then confirmed or cancelled with the reason, usually within a second. That is the trade-off: the customer hears "declined" a moment after placing, rather than in the response, as with the many real shops that confirm an order by email.

**Payment before shipping.** The card is *authorized* when the order is confirmed: a hold on the customer's balance, no money moved. It is *captured* — the charge itself — right after, and only a paid order is shipped. A temporary provider failure is retried inside Payments; a refused capture cancels the order before anything leaves the warehouse. (Capturing close to fulfilment is common card practice; the rules vary by card network and region.)

**Cancellation is a request** (`Orders::Order::Cancellable`), as in most real shops. Anyone may ask — the customer, a refused capture, a deadline — and the request is recorded at once, under the order's lock. Whether it can still happen is Fulfillment's to say, in a job, because only Fulfillment knows whether the carrier has the parcel — even before Orders has heard. If it has, the cancellation is refused, the refusal is recorded on the order, and a return is the way back. Otherwise the order is cancelled, with `OrderCancelled` staged in the same transaction, and every run of the job gives back the stock and asks Payments to *release* the payment. Payments voids the hold if nothing was captured and refunds if something was, deciding from its own state when it runs: an order not yet marked paid can have a capture that landed before Orders heard of it.

**Deadlines, not retry counts, give up on an order.** Retrying is infrastructure: every job retries a temporary failure until it succeeds, or ends in the failed jobs to be replayed once the cause is fixed. Giving up is a business decision, `Orders::Order::Expirable`'s, taken by `Orders::DeadlineSweepJob` every minute: an order placed but not confirmed within two minutes, so the customer hears within minutes whatever is failing, and an order confirmed but not paid within thirty, has its cancellation requested with the reason. A job still working on such an order finds it cancelled on its next run and does nothing — or, if it was confirming, gives back what it had just taken.

**Carrier reports arrive in any order.** The workers run in parallel and EventRail promises no ordering, so a delivery can be handled before the dispatch it follows. Orders' delivery subscriber then raises and is retried until the dispatch is recorded, rather than succeeding without effect and losing the delivery.

An order and its line items are one aggregate. **Returns** are an aggregate of their own (`Orders::Return`). The order checks its own rules — delivered, within 14 days, not already coming back — under its lock, and creates the return; from then on the return lives its own life: the carrier brings the parcel back, Orders restocks it and requests a refund, and the return is refunded when Payments reports it. A refund the provider definitively refuses sets the return aside for a person rather than retrying forever.

## Errors, retries and idempotency

**At a boundary, record the decision and stage what follows.** Every write that starts at a boundary follows this one rule: placing an order, a cancellation request, a return request, the deadline sweep. The domain method writes its decision and the job that carries it out in one transaction, and returns; the job does everything that touches another module, and retries until the shop matches the decision. Nothing that could need undoing happens inside a request, so a request that fails has changed nothing but its own, rolled-back transaction.

**A cart gives at most one order.** The order holds its cart's ID under a unique index, so placing a cart again — a double click, a retry after a timeout — returns that order, whatever its state, and runs nothing again. Two placements at once meet at the index, and the one that loses has touched nothing. A customer trying again after a cancellation fills a new cart.

**Work started by a domain method is staged with its data.** Placing an order writes the order and must also start confirming it: a dual write, since the queue is a separate database and enqueuing cannot join the order's transaction. Staging can. `order.confirm_later` stages `ConfirmJob`: it writes the job, in Active Job's own serialized form, to `platform_staged_jobs` in the same transaction as the order, and they commit or roll back together. `Platform::StagedJob` is also the shop's EventRail stager (`config.event_rail.stager`), so an event staged with `EventRail.stage` has its subscriber jobs written to the same table and handed over the same way. After the commit the job is handed to the queue at once; if that fails, `Platform::StagedJobRelayJob`, running every second, hands it over shortly after. A placed order is always confirmed or cancelled, whether or not the customer hears the answer. Handing a job over twice is harmless: it is the same command, and its events carry the same IDs because each declares its identity. A domain method stages wherever it runs — in a job too, where it costs a row and spares the job from having to be replayed — and the staging table must live in the store of the data it commits with. Every module shares one database here, so there is one table; a module moved to a database of its own would need a staging table there, a stager that routes each staging to the store whose transaction is open, and the relay taught to use it, while the queue keeps its own database. Inside a job, anything enqueued directly goes through `perform_later!`, which raises when the queue refuses it, so the job's own retry sends it again; Active Job's `perform_later` returns `false` instead, and the job would succeed having lost it.

**Every event declares what it is about.** Each event class names the attributes that identify its fact — `identity_by :order_id` for an order's `OrderPlaced`, `identity_by :reference` for a payment's `PaymentCaptured` — and EventRail derives the event's ID from them. The same fact has one ID however often, and from whichever job, it is published, so every subscriber recognises a repetition. The shop leans on this:

- Every event is staged in the transaction that records its fact, wherever that runs — placing an order in a request, capturing a payment in a job — so the fact and its announcement commit together, once. A step retried after its change committed finds the fact recorded and stages nothing again: the first run's event is already on its way.
- The identity still matters: the relay can hand a staged job over twice, and a subscriber then sees one event ID twice.

**Every reaction is idempotent** — a conditional update of the row, or a unique index on the order and the kind of fact — because delivery is at least once. A handler repeated after an interruption takes every step its state calls for, not only the ones that follow a change it made itself. And every job retries under one policy, chosen by the failure's category rather than declared job by job, so one failed attempt never strands an order. A job whose worker dies mid-run is failed by Solid Queue outside any `retry_on`; `Platform::RetryInterruptedJobsJob` runs such jobs again every minute.

**A payment makes one provider call at a time** (`Payments::Payment`). Callers ask for two things — the money taken, and the money given back — and each request is recorded on the payment under its lock as a `Payment::ProviderCall`: a capture, a void or a refund, pending, then sent, then answered (or superseded). A unique index keeps at most one call outstanding per payment, so a capture and a void are never outstanding together, and the payment's own state says only where the money last stood: authorized, captured, voided or refunded. A release, once asked for, stays asked for: a capture never starts after it, a capture not yet sent is called off, and one already sent is waited for, since only its answer says whether to void or refund. A capture that times out stays sent, because nobody knows whether the money was taken; its job retries, and if it ends in the failed jobs, replaying it asks the provider again under the same idempotency key, and the release follows the answer. A job for a call already answered or superseded finds nothing outstanding and does nothing. One logical call at a time is not one HTTP request at a time: two retries of a sent call can overlap, and only the provider's idempotency key makes that safe. Real providers keep those keys for a limited time — about a day, for some — and report some outcomes later, by webhook; a real application records those answers on the same call, and runs a sweep that asks the provider about calls left sent. The example leaves both out.

The patterns, in short: **record the decision and stage what follows**; **ask the module that owns a step for its state before undoing it**; **identify each event by its fact, and stage it with the change it reports**; **take the next step whenever the state calls for it**; **retry an unmet prerequisite rather than dropping the fact**; **let deadlines, not retries, give up**.

**Lineage.** Every request is a flow of its own: `Platform::ApplicationController` opens EventRail's context with the request's ID, every job that includes `EventRail::JobContext` carries it on, and every event records its correlation and causation. So a request's log lines, and every job and event it causes, share one ID. Each run of the deadline sweep is a flow too. An order's whole life — placed on Monday, returned on Friday — spans several flows; it is found by its own ID and reference, which every event carries, not by a correlation.

**Every error says what a caller should do.** A module's error is named for what happened — `NotCancellable`, `Declined` — lives in the module's namespace, one public file each in `app/public/<module>/`, and includes one of Platform's categories, named after gRPC's status codes: `FailedPrecondition`, `Unavailable`, `Aborted` and the rest (`Platform::ErrorCategory`). Only infrastructure reads the category. `Platform::ApplicationJob` holds the shop's one retry policy: a temporary failure is retried with backoff, a lost race quickly, an expected failure nobody handled fails at once, and an error with no category — a bug, or something nobody has classified — is retried and then left in the failed-jobs list. Code never logs an error and raises it again: it reports it to `Rails.error`, or lets it propagate to where Rails reports it. See [Observability](#observability) for where reports go.

## Observability

Rails has one instrumentation bus and three outlets. `ActiveSupport::Notifications` is the bus: Rails, gems and EventRail (`publish.event_rail`, `perform_subscriber.event_rail` …) publish timed hooks on it. `Rails.logger` writes text for people. `Rails.error` carries exceptions, to error trackers. `Rails.event`, new in Rails 8.1, carries structured events — a name, a payload, tags and context — to whatever the application registers; Rails emits its own requests and jobs there too, and registers nowhere to write them. The shop uses each for what it's for, all wired in the Platform engine (`engines/platform/lib/platform/`):

- **Every error becomes one structured event.** `Rails.error` is the one door for exceptions, Rails' own unhandled ones included. `Platform::ErrorSubscriber` turns each report into `platform.error_reported`, with the error's class, category, severity and whether it was **expected** — an outcome the shop answered, such as a refused cancellation, to be counted — or not, for someone to look at.
- **Domain events show up too.** `Platform::EventRailEvents` turns EventRail's notifications into `event_rail.published`, `event_rail.staged`, `event_rail.subscriber_enqueued` and `event_rail.subscriber_performed`, with the event's type, ID and correlation, so the log shows a whole flow. It lives in the shop, not the gem: the Rails API it uses is 8.1's and still settling. These telemetry events *describe* domain events such as `OrderPlaced`; they are not the same thing.
- **Everything carries its request or job.** `Platform::Observability.set_context` sets the request ID, job ID and EventRail correlation and causation once per request (the base controller) and per job (the base job), into both `Rails.error`'s and `Rails.event`'s context.
- **One logger, one level, one line per thing that happened.** Events are written through `Rails.logger`, and each environment chooses how (`config.platform.event_log`). In production, `Rails.logger` formats every line as one JSON object (`Platform::EventLog::JsonFormatter`), gems' and Solid Queue's included, and Rails' text log subscribers for requests, jobs, redirects and views are detached, because their structured events say the same: a request is its `Started GET` line, which Rails writes directly, plus `action_controller.request_completed`. In development the log stays Rails' familiar text, with the shop's own events as readable lines. Tests log no events; they assert on them (`assert_event_reported`). Rails 8.2 rebuilds the text log on `Rails.event`, which makes the detaching unnecessary.

A request's correlation is its ID. A request joining a flow that began elsewhere — a mobile app or another service sending `X-Correlation-ID` — would pass it to `EventRail.with_context(correlation_id: …)`, after checking it, since a header is untrusted input.

**For production**, the shop adds no gems, but each concern has its place:

- **Errors:** an error tracker (Sentry, Honeybadger) subscribes to `Rails.error` beside the shop's subscriber, wrapped so that only unexpected errors reach it: `Rails.error.subscribe(UnexpectedOnly.new(Sentry::Rails::ErrorSubscriber.new))`, where `UnexpectedOnly#report` returns early when `Platform::ErrorCategory.expected?(error)`. Alerts come from the tracker.
- **Metrics:** counters derived from the bus or from `Rails.event` — Yabeda with Prometheus, as 37signals does, or Shopify's statsd-instrument — including `platform.error_reported` by category and expectedness.
- **Traces:** OpenTelemetry's Rails instrumentation, with the trace ID added to the event context so logs and traces join.
- **Jobs:** Mission Control for Solid Queue's queues and failed jobs.

## An event that changed shape

`OrderPlaced` version 1 carried the total as an integer `total_cents`. Version 2 carries a `Money` with its currency. Retyping a field breaks every reader, so it is a new version, not an edit:

1. Subscribers learned to read both — `subscribes_to Orders::Events::OrderPlaced, Orders::Events::OrderPlacedV1`.
2. The publisher switched to version 2.
3. Once no version 1 message can still be queued, the old class and the old branch can go.

The example stays between steps 2 and 3 on purpose. The queue refers to an event by type and version, never by class name, so the old class could be renamed `OrderPlacedV1` without breaking what was queued.

## A module that joined later

Loyalty was added after the rest of the shop. It took an engine, one `require_relative` in `config/application.rb`, and a `package.yml` depending on `Orders`' published events — and no existing module changed. It hears `OrderDelivered` and `OrderRefunded`, and when it fails, orders are still delivered. That is the property EventRail exists for: the code that announces a fact learns nothing about who listens.

Loyalty awards points on delivery and takes them back on refund. A shop that wants points only once a return is no longer possible would have Orders publish an `OrderCompleted` when the return window closes, from a sweep like the deadline sweep. The window is Orders' rule, so Loyalty must not count the days itself.

## Anatomy of a module

```
engines/orders/
  lib/orders/engine.rb             isolate_namespace Orders; requires only Platform, whose ModuleEngine it extends
  bin/rails                        the module's own Rails command: generators write into the module
  package.yml                      its dependencies, enforced by packwerk
  app/public/orders/*.rb           Orders' public errors, one file each
  app/public/orders/events/        Orders::Events: published events, a package of their own
    package.yml                    dependencies: [] -- an event can never reach into Orders
  app/controllers/orders/          Orders' HTTP API, using its models directly
  config/routes.rb                 the engine's routes, mounted by the host
  app/models/orders/, app/jobs/orders/, db/migrate/, test/
```

- **A module other modules call has an `Api`**, in `app/public/<module>/api.rb`, holding exactly what they call and nothing else. Catalog, Payments and Fulfillment have one; Orders, Notifications and Loyalty have none, because no module calls them. An `Api` returns plain `Data` values or nothing, never records: packwerk sees only constant references, and a record returned across a boundary would hand out its whole association graph without a violation being reported.
- **Published events are a separate package.** A module that only reacts to Orders depends on `engines/orders/app/public/orders/events` alone: it can subscribe, and cannot call Orders' API or read its tables. Because the events package depends on nothing, two modules can hear each other's events without a package cycle. `config.event_rail.roots << "app/public"` is what makes EventRail discover every module's published events at boot.
- **An internal event** — one only its own module hears — would sit directly in the namespace, outside `app/public`, and packwerk would report any other module referencing it.

Not every module needs to be an engine. **An engine** when it needs Rails: models, migrations, jobs, routes. **A plain package** — a folder with a `package.yml` on an eager-load path — when it is plain Ruby for this application. **A local gem** when it should work without this application; packwerk then sees only what the gem references, not who references it, and it does not reload in development.

## Boundaries, enforced, not described

```sh
bin/packwerk validate   # the dependency graph has no cycle
bin/packwerk check      # no module references another's internals or an undeclared module
```

Both run in CI. `test/boundaries` plants rule-breaking files into a copy of the application — a private model reached from outside, an undeclared dependency, an upward call, a published event reaching into its module, another module subscribing to an internal event, a declared cycle — and asserts each is caught. The rules apply to tests too. `test/boundaries` also checks two things packwerk cannot see: every error has a category, which decides how it is retried, and the recurring schedule names jobs that exist.

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
bin/rails test test engines/*/test   # modules, whole flows, boundary probes
bin/ci                               # everything CI runs
```

Module tests live with their module in `engines/<module>/test`, and read its records directly. Tests of other modules read them through the module's **test support** (`engines/<module>/test/support/<module>/test_support.rb`, such as `Payments::TestSupport.payment(reference)`): it lives with the module, so it may use the module's models, and it is outside the load paths, so only tests can load it. Nothing is added to an `Api` for a test. Each engine has its own `bin/rails`, so `bin/rails generate model Refund` run in `engines/payments` writes `Payments::Refund` and a `payments_refunds` migration into Payments. Whole-flow tests in `test/flows` work off the queue one job at a time, as a worker does, and check what every module ended up with through that module's test support. The `example` job in the gem's CI runs all of it on every pull request, against the gem's current source.
