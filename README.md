# EventRail

[![CI](https://github.com/alexdmtv/event-rail/actions/workflows/ci.yml/badge.svg)](https://github.com/alexdmtv/event-rail/actions/workflows/ci.yml)

When a Rails application grows, the code that places an order ends up naming everything that should happen next: send the confirmation email, update the loyalty balance, notify the warehouse, write the analytics row. Each addition is another dependency in the one place that can least afford them.

There are two ways for one part of an application to reach another. The synchronous one — call a method, get an answer — Ruby hands you for free, and it is the one above: the caller names the callee. The other inverts it. One part announces a fact, and whoever cares subscribes. The dependency does not vanish: a subscriber still names the event, and the event belongs to the code that publishes it. But it points the other way, and it is far narrower: a dependency on something that happened, not on how the other side works. What matters is the side that accumulates. Code that invokes every interested party learns a new name for each one; code that announces a fact learns nothing.

Rails ships no way to express the second. `ActiveSupport::Notifications` is in-process and untyped, Active Record callbacks are the coupling you were trying to escape, and an event store asks you to adopt a storage model in order to send one message across a boundary.

EventRail is that second interface. An event is an immutable, versioned value. Every subscriber is an ordinary Active Job that keeps its own queue, retry policy, and concurrency limits, and delivery goes through the queue adapter you already run. The publisher never names a subscriber. There is no transport, no registration API, and no runtime of its own.

EventRail is pre-1.0: the public API may change in a minor release, and every change is documented in the [CHANGELOG](CHANGELOG.md). Delivery semantics, safety limits, and the notification contract are settled and documented below.

## When to use EventRail

EventRail is narrow on purpose: durable fanout across a boundary inside one application, where each subscriber retries independently and the same fact keeps the same identity across every retry and every hop. Reaching for an event store to get that means adopting its storage model too: entities as streams, state rebuilt from history. That is a large commitment for what is, at the boundary, one message. If you want that commitment, or something else entirely, these fit better.

| If you need | Use | Because |
| --- | --- | --- |
| An event log: audit history, replay, rebuilding read models | [Rails Event Store](https://railseventstore.org) | It is a store. Events persist in the same transaction as the state that produced them, which also closes the dual-write gap below. |
| Handlers that run inside the same request | [downstream](https://github.com/palkan/downstream) | Delivery is synchronous by default, async opt-in per subscriber. |
| In-process decoupling and nothing more | `ActiveSupport::Notifications` | Already in your application. No gem, no contract, no queue. |
| Events to be the system of record, not a message | [Sequent](https://www.sequent.io) | A full event-sourcing framework: commands, aggregates, projectors. |

**Why not call `perform_later` three times?** That is already durable fanout, and for three jobs in one method it is the right answer. EventRail earns its place when the publisher should not know its subscribers, when the payload needs a versioned contract that outlives a worker running older code, and when a retry must not produce a second copy of a fact already recorded.

### What it gives you

- **Stable identity.** An event that declares what fact it is has one ID wherever and however often it is published, so a consumer recognises it arriving again; any other event keeps its ID across retries and redeliveries. Idempotency holds across hops, not only across one subscriber's retries.
- **Subscribers that are the jobs**, each keeping its own queue, retry policy, and concurrency limits rather than sharing the single wrapper job other gems route subscribers through.
- **Boot-time validation**: a wrong `perform` arity, a missing `EventRail::JobContext`, or a late declaration fails the boot that introduced it rather than the first publication in production.
- **A typed boundary**: a `Date`, a `BigDecimal`, a record, or a GlobalID is refused rather than serialized into something a worker cannot restore.
- **Your own layout**: discovery matches a path suffix against the autoload roots Rails already has, covering engines and a packwerk-style `packs/billing/app/jobs` with no configuration.
- **No Active Record**, table, migration, or initializer.

### What it does not do

- **No event log and no synchronous handlers.** No history, replay, read-model rebuild, or browser UI, and every subscriber crosses the queue. A subscriber can append every event to a store of your own, keyed on `(source, id)`, but that store is a downstream log, not event sourcing: publication follows the commit, with no ordering or expected-version guarantees, so the store is a copy of what happened rather than its source of truth.
- **No outbox, and so a dual-write gap.** Publication is refused inside a transaction, so a publisher commits and then publishes, and a process that dies between the two loses the event. Publishing from a job makes that recoverable, because the retry republishes under the same identity (see [Replay-safe publishers](#replay-safe-publishers)); a controller action has no retry to repeat the publication, though an event with declared identity keeps its ID when anything does. An application that wants recovery beyond that records the intent to publish in the same transaction as its data, and a sweeper or a relay job publishes it; an event with [declared identity](#identity-occurrence-time-and-source) derives the same ID however many times it is republished, so consumers see a repetition rather than a new fact.
- **Discovery is enforced, not advisory.** A subscriber outside a [discovery root](#where-discovery-looks) fails the boot rather than being quietly ignored: a silent delivery bug traded for a loud startup error, at the price of a layout rule.

## Requirements

- Ruby 3.3 or newer
- Rails 7.2, 8.0, or 8.1

EventRail depends on Active Support, Active Model, Active Job, Railties, and Zeitwerk. It does not require Active Record.

## Installation

```ruby
# doc:illustrative
gem "event_rail"
```

Then run `bundle install`. There is no initializer to generate and nothing you have to configure: EventRail initializes itself through a Railtie, every safety limit is a fixed documented constant, and the one option it does expose, [where it looks for events and subscribers](#where-discovery-looks), has a default that most applications never change.

## Job integration

One explicit inclusion, on each job base class that should carry logical context:

```ruby
class ApplicationJob < ActiveJob::Base
  include EventRail::JobContext
end
```

That is the entire integration. EventRail does not prepend `ActiveJob::Base` globally, because changing serialization for jobs whose owners never asked for it is surprising, and it does not edit `ApplicationJob` from a generator, because applications may have several job bases or a customized one. Ordinary jobs that do not opt in are untouched.

## Events and nested data

Events use Active Model types and validations. Nested objects can be modeled as immutable `EventRail::Data` values, including arrays of typed objects:

```ruby
module Docs
  class LineItem < EventRail::Data
    attribute :product_id, :string
    attribute :quantity, :integer

    validates :product_id, presence: true
    validates :quantity, numericality: { greater_than: 0 }
  end

  class OrderPlaced < EventRail::Event
    event_type "docs.order_placed"
    version 1
    default_source "acme.orders"
    identity_by :order_id

    attribute :order_id, :string
    attribute :total, :decimal
    attribute :placed_at, :datetime
    attribute :line_items, LineItem, array: true
    attribute :properties

    validates :order_id, presence: true
  end
end

event = Docs::OrderPlaced.new(
  order_id: "A-1001",
  total: "49.90",
  placed_at: "2026-09-01T10:30:00+02:00",
  line_items: [ { product_id: "P-1", quantity: 2 } ],
  properties: { "channel" => "web" },
  extensions: { "tenant" => "north" }
)

event.order_id                  # => "A-1001"
event.total                     # => BigDecimal("49.9")
event.line_items.first.quantity # => 2
```

Two views of the same payload, for two different jobs:

```ruby
event.attributes # cast values of the declared types: BigDecimal, Time, LineItem
event.data       # the portable projection: JSON primitives, arrays, string-keyed hashes
event.metadata   # immutable metadata; not yet stamped
```

`attributes` is Active Model's own meaning and is what application code reads. `data` is the single written form that both the queue representation and the public envelope use, so a `Date`, a `BigDecimal`, or a nested Ruby object never reaches a queue adapter or a codec.

Casting refuses to discard information rather than substituting a plausible value. `"abc"` is not `0`, `true` is not `"t"`, a timestamp needs an explicit offset, and a date attribute will not silently drop a time of day. An untyped attribute accepts only recursively JSON-like values: strings, integers, finite floats, booleans, `nil`, arrays, and string-keyed hashes. Those are bounded in nesting depth and forbidden from using the `_aj_` prefix Active Job reserves in its own argument encoding. Records, GlobalID values, arbitrary Ruby objects, non-finite numbers, undeclared attributes, and callable defaults are rejected.

Constructed events, nested data, metadata, and every contained value are recursively immutable. Two events of one class with equal payload and equal metadata are equal values, which is what lets `assert_enqueued_with(args: [event])` match a published event.

### Custom attribute types

A custom Active Model type may be used as an attribute type. Rails' `serialize` is documented as producing a value "usable by the database", and a database driver accepts a `Date` or a `BigDecimal` object. A queue does not, and Active Job does not recurse into a serializer's output, so such a value would reach the adapter raw. Including `EventRail::PortableType` narrows the promise to a JSON primitive, array, or string-keyed hash, and `portable_examples` makes the promise checkable:

```ruby
module Docs
  Weight = Struct.new(:grams)

  class WeightType < ActiveModel::Type::Value
    include EventRail::PortableType

    def cast(value) = value.is_a?(Weight) || value.nil? ? value : Weight.new(Integer(value))
    def serialize(value) = value&.grams
    def deserialize(value) = value && Weight.new(value)
    def portable_examples = [ Weight.new(0), Weight.new(2500) ]
  end

  class ParcelShipped < EventRail::Event
    event_type "docs.parcel_shipped"
    version 1
    default_source "acme.shipping"
    identity_by :parcel_id

    attribute :parcel_id, :string
    attribute :weight, WeightType.new
  end
end

Docs::ParcelShipped.new(parcel_id: "P-1", weight: 2500).data
# => { "parcel_id" => "P-1", "weight" => 2500 }
```

Every example is round-tripped through JSON when the attribute is declared, so a type that cannot hold up fails at class definition rather than at the first enqueue. A type whose cast value is already a portable scalar (a plain `:string` subclass, say) needs none of this.

## Publishing

```ruby
module Docs
  # app/jobs/billing/charge_card_job.rb
  module Billing
    class ChargeCardJob < ApplicationJob
      queue_as :payments
      retry_on Timeout::Error, attempts: 10

      subscribes_to OrderPlaced

      def perform(event)
        Rails.logger.info("charging #{event.order_id} idempotently on #{event.id}")
      end
    end
  end

  # packs/analytics/app/jobs/analytics/record_order_job.rb
  module Analytics
    class RecordOrderJob < ApplicationJob
      queue_as :low
      discard_on ActiveJob::DeserializationError

      subscribes_to OrderPlaced

      def perform(event)
        Rails.logger.info("recording #{event.order_id}")
      end
    end
  end
end

publication = EventRail.publish(
  Docs::OrderPlaced.new(order_id: "A-1002", total: "10.00", placed_at: Time.now.utc.iso8601)
)

publication.event                # the stamped, immutable fact
publication.accepted_subscribers # subscribers whose enqueue was accepted
publication.skipped_subscribers  # subscribers whose own enqueue callback declined
```

Billing and analytics do not know about each other, and the publishing code names neither. Adding a third subscriber is adding a file; the code that publishes `OrderPlaced` never changes. Each one keeps its own queue and its own failure policy, because each one is just a job. A payment that retries for ten attempts and an analytics write that is discarded when its event can no longer be loaded are the same fanout, configured separately.

Subscribers are discovered from the conventional `app/events` and `app/jobs` roots of the host application and every engine, during Rails preparation. There is no registration API, no initializer, and no registry to query.

### Where discovery looks

```ruby
# doc:illustrative
# config/application.rb
config.event_rail.roots << "app/subscribers"   # default: %w[app/events app/jobs]
```

Each entry is matched as a path suffix against the autoload roots Rails already has, so one entry covers the host application, every engine, and a packwerk-style `packs/billing/app/jobs` without naming any of them. Appending is additive: the defaults stay in effect.

Two things to know before reaching for it. A configured root is eager-loaded during preparation in **every** environment, so naming something broad like `app/models` loads that directory for the application and every engine on each boot and each reload; moving the file is usually the better fix. And a root you name that is not an autoload root of the application or any engine fails preparation with `EventRail::ConfigurationError`, so a typo is a boot error rather than a directory that silently discovers nothing. A *default* root the application has not created is simply skipped, so a fresh application with no `app/events` directory boots normally.

`subscribes_to` is exact and not inherited on either side. A subclass of a subscriber is a different job and receives nothing. A subscriber must define its own `perform` taking exactly one required positional event parameter, must not have subclasses, and must include `EventRail::JobContext`. Each of those is checked during preparation, so a mistake fails the boot that introduced it rather than the first publication. The event class a subscription names must declare a contract of its own. Neither `event_type` nor `version` is inherited, so a shared abstract base and a subclass that adds nothing of its own are both refused, and refused at the declaration itself rather than during preparation, because the class is already loaded by the time the macro reads it. A class that declares one of the two and not the other is a broken contract rather than a base, and still fails preparation naming the event class.

A subscriber must also be reachable by name, because Active Job enqueues a job by name. Declaring a subscription on a class that has none raises immediately, so `Foo.const_set(:Bar, Class.new(ApplicationJob) { subscribes_to Baz })` is not supported; name the class first. The check is on the name the class carries, not on whether a constant resolves to it, so a class with a name nothing resolves to is still dropped from the registry without comment; that is a deliberate limit, not an oversight.

One rule covers both halves of discovery: **an event contract or a subscription declared after preparation has sealed the registry raises**, naming the file and line and the two ways to fix it. EventRail refuses to run with a subscriber that would receive nothing, or with an event class a worker could not reconstruct from the queue.

Adding the directory to `config.eager_load_paths` is never enough on its own, and the reason is Rails' own ordering: prepare callbacks run *before* `eager_load!`, so a reloadable class outside a discovery root cannot be loaded in time in any environment. Either move the file under a discovery root, or [add its root](#where-discovery-looks).

Two exceptions. Code that is not reloadable at all, such as a gem or a file plainly required from an initializer, ran its declaration before preparation, so it is already registered; such a file has to bring its own event class and job base, because initializers run before the main autoloader exists. And a test suite loads after preparation by definition, which is what [`EventRail::TestHelper`](#tests-that-need-their-own-fixtures) is for.

### At-least-once delivery, and what that means for subscribers

Fanout is individual `perform_later` calls, one per subscriber. Jobs already accepted are never rolled back when a later subscriber's enqueue fails, and the retry repeats complete fanout under the same event ID. A subscriber must therefore be idempotent. An event's full identity is `(source, id)`, so a subscriber records `(subscriber, event.source, event.id)` in the same transaction as its effect and does nothing when that record already exists; a business-key constraint (one refund per order) remains worth having beside it. The ID is stable across retries of the publishing execution and redeliveries of a subscriber's own cause, and, for an event with [declared identity](#identity-occurrence-time-and-source), across every publication of the fact.

Two copies of one fact, published by different executions, can differ: a later `occurred_at`, another causation, or a payload read from state that has since changed. EventRail stores nothing and orders nothing, so it cannot say which copy is authoritative; each subscriber decides, and publishers keep copies equal by building events from persisted data.

No ordering is promised, between subscribers or between events.

Retries, backoff, discarding, and dead-letter handling stay where they already are: each subscriber's own Active Job configuration and the configured queue adapter. EventRail adds no retry policy of its own and no failure queue.

### Publishing inside a database transaction

Don't. Publication raises `EventRail::TransactionalPublicationError` when a transaction is open, in every environment, and the fix is to publish after the transaction commits.

Both queue deferral settings are wrong inside a transaction, in opposite directions. With `enqueue_after_transaction_commit` on, the enqueue is deferred past the point where its failure can be reported, so a publication that silently enqueued nothing looks successful. With it off, the enqueue announces a fact that a rollback then contradicts. The check is on the open transaction itself, so it does not depend on the setting, or on Active Record being present at all.

### Replay-safe publishers

A publisher that applies a state transition and then publishes should make the transition idempotent and attempt publication unconditionally:

```ruby
module Docs
  class PlaceOrderJob < ApplicationJob
    def perform(order_id)
      order = { id: order_id, placed: true } # stands in for an idempotent state transition
      EventRail.publish(Docs::OrderPlaced.new(order_id: order[:id], total: "1.00", placed_at: Time.now.utc.iso8601))
    end
  end
end
```

Guarding publication behind "did I already transition?" is the failure mode to avoid: a crash between the transition and the enqueue then leaves an event that is never published. Attempting publication every time is safe, because a second publication of the same logical fact in the same execution is rejected as a duplicate, and a retry after a failed fanout reuses the identity already stamped.

## Identity, occurrence time, and source

An event's ID says which fact it is, so a consumer can recognise the same fact arriving again. It is chosen by one of three rules, in order:

1. **An event that already carries an ID** — one reconstructed from an envelope — keeps it, with its source and its lineage.
2. **An event with declared identity** — its class's `identity_by` attributes, or an `identity:` passed to `publish` — derives its ID from its source, its event type and that identity, and from nothing else: not the job that published it, not the execution, not the schema version. The same fact has the same ID wherever and however often it is published, inside a job or in a controller, and in version 1 or version 2.
3. **Any other event** derives its ID from the execution publishing it: stable across that job's retries, and, for an event a subscriber publishes, across redeliveries of the event it handles. A separate job publishing it again gets a new ID. Outside a job it gets a random, time-ordered ID.

**Identity names the occurrence, not the thing it is about.** This is the rule to get right, because getting it wrong fails silently. `PaymentCaptured identity_by :reference` is right when a payment is captured once. `PriceChanged identity_by :product_id` is wrong: every price change of that product would carry one ID, and consumers would drop all but the first, with no error anywhere. A fact that can happen again for the same thing keys on what distinguishes each occurrence — a persisted change ID, a revision, an import row — never on a hash of the payload or a loop index:

```ruby
module Docs
  module Inventory
    # One base class per producer, so its source is declared once.
    class Event < EventRail::Event
      default_source "acme.inventory"
    end

    # Stock is adjusted many times; each adjustment is one fact.
    class StockAdjusted < Event
      event_type "docs.stock_adjusted"
      version 1
      identity_by :adjustment_id

      attribute :adjustment_id, :string
      attribute :sku, :string
      attribute :quantity, :integer
    end

    class StockCounted < Event
      event_type "docs.stock_counted"
      version 1

      attribute :sku, :string
      attribute :counted, :integer
    end
  end
end

first = EventRail.publish(Docs::Inventory::StockAdjusted.new(adjustment_id: "adj-7", sku: "MUG", quantity: -2)).event
again = EventRail.publish(Docs::Inventory::StockAdjusted.new(adjustment_id: "adj-7", sku: "MUG", quantity: -2)).event
raise "one adjustment, one ID" unless first.id == again.id

# A class without identity_by can name the fact at the call site instead.
EventRail.publish(Docs::Inventory::StockCounted.new(sku: "MUG", counted: 38), identity: "count-2026-09-01-MUG")
```

Beside that rule:

- **`identity:` names a fact across every job**, so it must be unique per source and event type. It is refused for a class that declares `identity_by`, so the two cannot disagree, and it derives the same ID as a single string `identity_by` attribute with the same value, so a class can move from one to the other without changing IDs; an integer `42` and the string `"42"` are different identities.
- **A tenant belongs in the identity** (or the source) when tenants number their facts independently; an extension is not part of an event's identity.
- **Never use personal data as identity.** The derivation is a hash, and a hash over an email address or a name is reversible by guessing.
- **Events that cross an application boundary should declare identity.** An execution-derived ID changes when the publishing code moves, a declared one does not.
- **Changing `source`, `event_type` or declared identity changes IDs**, so each is a breaking change. Renaming a subscriber class changes the IDs of undeclared events it publishes.

Upgrading from a release where `publish` took `key:`: that key was scoped to one job and is now `identity:`, scoped to every job. Before renaming it, and for every `identity_by`, check that the value names one occurrence per source and event type; a value that used to be safe inside one job, such as a line number, now merges facts.

`occurred_at` is the logical publication time: an explicit timezone-aware value is preserved as the same instant, and otherwise it is the start of the current execution, stable across that execution's retries and never inherited from a cause. Use a persisted domain timestamp when business occurrence time matters, and build an event from persisted data, so that two publications of one fact carry the same payload. Stored times are UTC at microsecond precision.

`source` names the logical producer of an event — `acme.orders` — not an environment, queue, topic, cluster, or deployment. An event ID is unique within its source, so `(source, id)` is an event's full identity, as in CloudEvents, and the source is half of every declared ID. Choose it for the producer rather than the deployment, and a module can move to another application without its events changing IDs. Declare it once, with `default_source` on a module's base event class; an event built on behalf of another producer can be published with `source:` (see [Crossing a network boundary](#crossing-a-network-boundary)). Any bounded non-empty string is accepted, and EventRail does no URI parsing. A follow-up event records its cause's ID as its causation, not its cause's source.

### How an ID is derived

Other implementations can derive the same IDs. An ID is a UUIDv5 ([RFC 9562](https://www.rfc-editor.org/rfc/rfc9562.html)) under the namespace `21fedac0-42c6-443f-b01c-6980aab52f32`, over a name that concatenates encoded components:

- **Declared identity:** `"fact"`, source, event type, and the identity as a list — the `identity_by` values in declaration order, or the one `identity:` value.
- **Execution:** `"execution"`, source, job class name, scope, event type, version, and a singleton marker. The scope is a regular job's Active Job ID, or, for a subscriber, the list `[source, id]` of the event it handles.

Each component is encoded as a tag, its byte length in decimal, a colon, and its bytes:

| Value | Tag | Bytes |
| --- | --- | --- |
| String | `s` | its UTF-8 bytes, without Unicode normalization; invalid UTF-8 is refused |
| Integer | `i` | decimal, with a leading `-` when negative |
| Decimal | `d` | plain notation: an optional `-`, the integer digits, `.`, and the fractional digits with trailing zeros removed but at least one kept (`12.5`, `100.0`, `0.0`, `-0.0`) |
| Float | `f` | 17 significant digits with trailing zeros removed, as C's `printf("%.17g")` writes them: positional notation, or exponent notation (`1e+22`, `9.9999999999999995e-08`) when the decimal exponent is below -4 or at least 17, the exponent with a sign and at least two digits; `-0` stays distinct from `0`; non-finite is refused |
| Boolean | `b` | `true` or `false` |
| Date | `D` | ISO 8601 (`2026-09-01`) |
| Timestamp | `T` | converted to UTC, truncated to microseconds, and written as ISO 8601 with six fractional digits (`2026-09-01T10:30:00.123456Z`) |
| List | `L` | the item count in decimal, a colon, then each item encoded |
| Singleton marker | `*` | empty |

These vectors are part of the contract, and the test suite asserts them. For declared identity the source is `acme.orders` and the event type `orders.order_placed`; for execution, the job class is `Orders::PlaceOrderJob` and the version `1`:

| Vector | Encoded name | ID |
| --- | --- | --- |
| a string | `s4:facts11:acme.orderss19:orders.order_placedL8:1:s3:o-1` | `13b2cda9-e1f7-57b6-ba1d-bb12a7553655` |
| a non-ASCII string | `s4:facts11:acme.orderss19:orders.order_placedL12:1:s7:Zürich` | `8ad8bbf8-3e10-5162-97da-53cb6752973f` |
| an integer | `s4:facts11:acme.orderss19:orders.order_placedL7:1:i2:42` | `43230f76-4e80-55d0-bfaf-beab63ac76b9` |
| a negative integer | `s4:facts11:acme.orderss19:orders.order_placedL7:1:i2:-7` | `4feffb91-0dec-5a7b-a5a0-67968abbe971` |
| true | `s4:facts11:acme.orderss19:orders.order_placedL9:1:b4:true` | `b1a75e27-6aa2-5f7e-9159-fb429bddc17f` |
| false | `s4:facts11:acme.orderss19:orders.order_placedL10:1:b5:false` | `631f1712-795b-59fa-b497-103b5f951306` |
| a decimal | `s4:facts11:acme.orderss19:orders.order_placedL9:1:d4:12.5` | `fc8e4be7-4912-5702-b22b-92d63d710e01` |
| an integral decimal | `s4:facts11:acme.orderss19:orders.order_placedL10:1:d5:100.0` | `4ab51db7-7864-591d-8e1a-b1f5d9567169` |
| a zero decimal | `s4:facts11:acme.orderss19:orders.order_placedL8:1:d3:0.0` | `0a066901-77e5-55e3-99c4-a973b5018500` |
| a negative zero decimal | `s4:facts11:acme.orderss19:orders.order_placedL9:1:d4:-0.0` | `784aef76-53c9-517c-ba3f-732053cd537d` |
| a float | `s4:facts11:acme.orderss19:orders.order_placedL25:1:f19:0.10000000000000001` | `cc223477-2cb1-5a6d-8d0f-6b25aaf989b7` |
| an integral float | `s4:facts11:acme.orderss19:orders.order_placedL6:1:f1:1` | `901836d7-5477-5780-8e6b-dd39ed49d272` |
| a large float | `s4:facts11:acme.orderss19:orders.order_placedL10:1:f5:1e+22` | `d4e88ebb-fdaa-5cc4-9dbe-c576abae6f36` |
| a small float | `s4:facts11:acme.orderss19:orders.order_placedL28:1:f22:9.9999999999999995e-08` | `83b232ee-36bc-53dc-a455-5a9e31a003a2` |
| negative zero | `s4:facts11:acme.orderss19:orders.order_placedL7:1:f2:-0` | `7cab07fc-874c-59ff-a946-76d00585d229` |
| a date | `s4:facts11:acme.orderss19:orders.order_placedL16:1:D10:2026-09-01` | `84aaf8b3-7dc1-5446-880d-a002bfe8cab6` |
| a timestamp | `s4:facts11:acme.orderss19:orders.order_placedL33:1:T27:2026-09-01T10:30:00.123456Z` | `874e797f-7b0c-5742-b8e2-6b05ae3f738a` |
| a timestamp with an offset and sub-microsecond digits | `s4:facts11:acme.orderss19:orders.order_placedL33:1:T27:2026-09-01T10:30:01.234567Z` | `7fcd39f5-1a94-5ad2-b899-22ac849d510d` |
| several values | `s4:facts11:acme.orderss19:orders.order_placedL12:2:s3:o-1i1:2` | `fe61e6d0-cbb6-5db0-96a4-1fd78d86dab9` |
| a regular job's scope | `s9:executions11:acme.orderss21:Orders::PlaceOrderJobs5:job-1s19:orders.order_placedi1:1*0:` | `e3c5921d-a9bf-5816-b9a7-f36f426cb998` |
| a subscriber's scope | `s9:executions11:acme.orderss21:Orders::PlaceOrderJobL59:2:s13:acme.paymentss36:0b1e2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4ds19:orders.order_placedi1:1*0:` | `a3a31754-e302-5c23-a4a7-ea353accfeb6` |

Random IDs, for events without declared identity published outside a job, are UUIDv7, so a log indexes them in time order, to the millisecond, and the version digit tells a random ID (7) from a derived one (5).

## Logical context

Application-owned ingress code establishes context; EventRail ships no HTTP middleware and no controller concern, and harvests nothing from headers, Rails current state, or tracing baggage.

```ruby
EventRail.with_context(message_id: "req-abc", extensions: { "tenant" => "north" }) do
  EventRail.publish(Docs::OrderPlaced.new(order_id: "A-1004", total: "7.00", placed_at: Time.now.utc.iso8601))
end
```

A nested scope inherits lineage and may add extensions or repeat identical values; replacing an inherited identifier, origin time, or extension value fails rather than rewriting the lineage of a flow already in progress.

Context extensions are durable baggage: opted-in child jobs carry them, and published events merge them with event-local extensions, rejecting conflicting values. They are not the place for domain data; that belongs in declared attributes.

### Reading context

A job that includes `EventRail::JobContext` runs with context already installed, and reads it from `EventRail::Current`:

```ruby
class ReconcileOrderJob < ApplicationJob
  def perform
    EventRail::Current.message_id     # this job's logical message
    EventRail::Current.correlation_id # constant across the whole causal tree
    EventRail::Current.causation_id   # what caused this job
    EventRail::Current.originated_at  # when the flow started, a UTC Time
    EventRail::Current.extensions     # frozen string-keyed baggage
  end
end
```

Those five readers are the whole surface. Outside a job they return `nil`, except `extensions`, which is always a frozen hash.

A subscriber is the case where they are usually unnecessary. Its logical message is the event it is handling rather than the job delivering it, so `Current.message_id` **is** `event.id`, and correlation, causation, and extensions all come from the event that is already the method argument:

```ruby
class SendReceiptJob < ApplicationJob
  subscribes_to Docs::OrderPlaced

  def perform(event)
    event.id             # == EventRail::Current.message_id
    event.correlation_id # == EventRail::Current.correlation_id
    event.extensions     # == EventRail::Current.extensions
  end
end
```

Reach for `Current` in a subscriber only to hand lineage to something that does not take the event: a log line, an outbound request header, an APM tag.

Lineage is isolated per unit of concurrent execution through `ActiveSupport::IsolatedExecutionState`, which defaults to thread isolation. **A host running fibers, whether a fiber-per-request server or a worker that runs jobs on fibers, must set `config.active_support.isolation_level = :fiber`**, or lineage will be shared between concurrent fibers. That setting is Rails-wide rather than EventRail's, and it governs both `EventRail::Current` and EventRail's own publication state. EventRail documents the requirement rather than claiming an isolation it cannot provide.

Leaving it wrong fails loudly rather than silently: under thread isolation two concurrent fibers each establishing context raise `InvalidContext`, because the second inherits the first's identifiers and replacing them is refused. The rule that stops lineage being rewritten mid-flow doubles as a misconfiguration detector.

Under fiber isolation a fiber spawned by application code starts with no context at all, which is the isolation working as asked. Code that fans out over its own fibers and publishes from them should re-establish context inside each fiber rather than rely on inheriting it. A job running on a fiber-based worker needs none of that: its context arrives in the job's own serialized data, not from an ambient parent.

OpenTelemetry is not required. When standard Active Job instrumentation is installed, its own carrier and ambient span continue to work; EventRail never copies trace context or baggage into durable event metadata.

## Versioning events

`event_type` and `version` form the durable, language-neutral contract, independent of Ruby class names. A compatible optional addition may keep the same version: an older worker preserves the unknown field as opaque data with no reader and includes it again on export. Removing, renaming, requiring, or retyping a field, or changing its meaning requires a new version and a distinct class, and the old class stays registered while messages that reference it can still arrive.

A new version is a new representation of the same fact, so every version of a type keeps the same declared identity values, in the same order (an attribute may be renamed), and a fact with declared identity carries one ID in every version; an ID derived from the execution includes the version. A consumer subscribed to both versions while old messages drain deduplicates them on that ID. Keeping both representations is a different need: an archive stores `(source, id, version)`, and it must receive both, because a broker or inbox that deduplicates on `(source, id)` before routing by version passes only one of them on. Changing what an event identifies is not a new version but a new event type.

EventRail provides no upcasting and no schema registry.

## Fixed safety limits

| Value | Limit |
| --- | ---: |
| Event, correlation, causation, or boundary identifier, or `identity:` | 512 bytes |
| Source | 255 bytes |
| Event type | 255 bytes |
| Extension entries | 32 |
| Extension key | 64 bytes |
| Extension value | 1,024 bytes |
| Total extension key and value bytes | 8,192 bytes |
| Raw structure nesting depth | 32 |

Extension keys and values must be strings. Framework metadata names, tracing names, and the `eventrail.` prefix are reserved. There is no universal payload byte limit, because adapters and transports impose different ones.

## Testing

Application tests use Active Job's own helpers and nothing from EventRail:

```ruby
# doc:illustrative
publication = EventRail.publish(Docs::OrderPlaced.new(order_id: "A-1005", total: "1.00", placed_at: Time.now.utc.iso8601))

assert_enqueued_with(job: Docs::Billing::ChargeCardJob, args: [ publication.event ])
perform_enqueued_jobs
```

`assert_enqueued_with(args:)` works because events are value objects. For observability assertions, subscribe to the notifications below. EventRail ships no assertion library, observer, or contract-test helper; Active Job's helpers are the whole assertion surface.

### Tests that need their own fixtures

A test file loads after preparation, so declaring a throwaway event or subscriber in one would raise. `EventRail::TestHelper` is the door for it, and it is opt-in:

```ruby
# doc:illustrative
# test/test_helper.rb
require "event_rail/test_helper"

class ActiveSupport::TestCase
  include EventRail::TestHelper
end
```

Declare fixtures at file scope, in a window:

```ruby
EventRail::TestHelper.declare do
  module OrderTests
    class Placed < EventRail::Event
      event_type "docs.order_tests_placed"
      version 1
      default_source "tests"

      attribute :order_id, :string
    end

    class AuditJob < ApplicationJob
      subscribes_to Placed

      def perform(event) = Rails.logger.info(event.order_id)
    end
  end
end
```

**A subscriber declared in a window receives nothing until you activate it.** That is deliberate: a fixture that went live on declaration would fan out in every later test in the process, including tests that never mention it. Activate it for one block:

```ruby
# doc:illustrative
test "publication fans out to the audit job" do
  with_subscribers(OrderTests::AuditJob) do
    publication = EventRail.publish(OrderTests::Placed.new(order_id: "o-1"))

    assert_enqueued_with(job: OrderTests::AuditJob, args: [ publication.event ])
    perform_enqueued_jobs
  end
end
```

The previous registry is restored when the block exits, including when it raises, and nested activations are additive. Activation applies the same validation preparation does, so an abstract fixture fails there rather than at delivery.

Event contracts behave differently from subscribers on purpose: they are registered when the window closes and stay registered, because `assert_enqueued_with` deserializes the job it is comparing and so needs the contract outside any block. A class cannot be unloaded, which has one consequence worth knowing: **give each fixture a unique `event_type`, and declare it once, at file scope.** Two live classes claiming one type and version fail every later rebuild for the rest of the process, and a declaration inside a test method reopens the same constant and runs the writer again on a sealed registry.

Activation replaces a process-wide registry, so it is not safe under `parallelize(with: :threads)`. Process-based parallelisation, the Rails default, is unaffected.

## Notifications

Four `ActiveSupport::Notifications` events, all in block form so Rails' own exception keys report failures:

| Name | Additional payload |
| --- | --- |
| `publish.event_rail` | `subscriber_count`, `accepted`, `skipped` |
| `enqueue_subscriber.event_rail` | `job_class`, `outcome` (`accepted`, `skipped`, `failed`) |
| `deserialize.event_rail` | `format_version` |
| `perform_subscriber.event_rail` | `job_class` |

Every payload carries `event_type`, `event_version`, `event_id`, `source`, `correlation_id`, and `causation_id`. None carries domain data or extensions. Handlers run synchronously under normal Rails semantics, so they should neither raise nor do slow work.

## Crossing a network boundary

`EventRail::Envelope` is the format-neutral boundary. It exposes contract, metadata, and the portable data projection through readers, and produces no bytes, no canonical hash, and no content type: those decisions belong to whoever owns the transport.

```ruby
# doc:illustrative
envelope = EventRail::Envelope.of(publication.event)
payload  = MyCloudEventsCodec.encode(envelope)   # the application owns every byte
```

Inbound, the application maps a contract to a class with its own allowlist and then reconstructs explicitly. A type name arriving over a network never names a Ruby constant, and the internal queue registry does not authorize external input:

```ruby
# doc:illustrative
ACCEPTED = { [ "partner.invoice_issued", 1 ] => Billing::InvoiceIssued }.freeze

event_class = ACCEPTED.fetch([ envelope.event_type, envelope.version ])
EventRail.publish(envelope.to_event(event_class))
```

A relayed event keeps its origin's ID, source, occurrence time, correlation, causation (an absent one stays absent), and extensions; the relaying application's own context extensions are not merged into it. Relaying it with a different `source:` is refused rather than re-attributing somebody else's fact.

A producer that sends no event ID, a supplier's webhook say, is mapped to a local event built on the producer's behalf. Its declared identity and the producer's source make a retried delivery the same fact:

```ruby
EventRail.publish(
  Docs::Inventory::StockAdjusted.new(adjustment_id: "delivery-4411", sku: "MUG", quantity: 120),
  source: "supplier.warehouse"
)
```

Source is a claim, not a credential. Before relaying, an inbound adapter checks `envelope.source` against the sources that peer may speak for: a declared fact's ID is predictable, so an unchecked envelope claiming a local source could arrive first under a local fact's ID and make consumers drop the genuine one.

Loop prevention is application policy: an export policy that refuses to export an event whose source is not the local application stops a relayed event from bouncing back to the system it came from. EventRail has no concept of internal versus external, direction, topic, or transport marker.

Acknowledge a consumed message only after publication succeeds, and leave retry and dead-lettering to the transport.

## Upgrading and rolling back

The private Active Job representation and the job context entry each carry their own version, independent of any event's schema version. Both evolve as staged, read-before-write deployments:

1. Deploy a release that reads the old and the new form everywhere, while still writing the old one.
2. Only then deploy a release that writes the new form.
3. Remove the old reader only after every queued message in the old form is drained or expired.

Rolling back reverses that: a rollback is safe only to a release that can still read what the newer release wrote. A change to how an individual value is written is a different matter: that encoding is shared with the public envelope, so it is a breaking public change rather than a private format bump.

## Development

Run the core tests and linter with:

```sh
bin/test
bin/rubocop
```

The Appraisal gemfiles cover Rails 7.2, 8.0, and 8.1. The CI matrix covers Ruby 3.3, 3.4, and 4.0.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for the local workflow and [SECURITY.md](SECURITY.md) for reporting security issues.

## License

EventRail is available under the [MIT License](MIT-LICENSE).
