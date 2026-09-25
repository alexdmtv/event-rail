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

- **Retry-stable identity**, derived from the publishing execution rather than generated, so a redelivered cause produces the same event rather than a second copy of it. Idempotency holds across hops, not only across one subscriber's retries.
- **Subscribers that are the jobs**, each keeping its own queue, retry policy, and concurrency limits rather than sharing the single wrapper job other gems route subscribers through.
- **Boot-time validation**: a wrong `perform` arity, a missing `EventRail::JobContext`, or a late declaration fails the boot that introduced it rather than the first publication in production.
- **A typed boundary**: a `Date`, a `BigDecimal`, a record, or a GlobalID is refused rather than serialized into something a worker cannot restore.
- **Your own layout**: discovery matches a path suffix against the autoload roots Rails already has, covering engines and a packwerk-style `packs/billing/app/jobs` with no configuration.
- **No Active Record**, table, migration, or initializer.

### What it does not do

- **No event log and no synchronous handlers.** No history, replay, read-model rebuild, or browser UI, and every subscriber crosses the queue.
- **No outbox, and so a dual-write gap.** Publication is refused inside a transaction, so a publisher commits and then publishes, and a process that dies between the two loses the event. Publishing from a job makes that recoverable, because the retry republishes under the same identity (see [Replay-safe publishers](#replay-safe-publishers)); from a controller action there is no such guarantee. An application that wants recovery beyond that can record an intent and republish it from a sweeper, but a republication from a different job derives a different event ID, so the intent's own key belongs in the payload for consumers to deduplicate on.
- **Discovery is enforced, not advisory.** A subscriber outside a [discovery root](#where-discovery-looks) fails the boot rather than being quietly ignored: a silent delivery bug traded for a loud startup error, at the price of a layout rule.

## See it in an application

[`examples/shop`](examples/shop/README.md) is a small online shop built as a modular Rails application: nine engines with boundaries enforced by packwerk, talking through method calls where an answer is needed now and through EventRail events where it is not. It runs with a simulator and a live console that draws every order's causal tree, so you can dial in faults and watch retries, redeliveries and failure isolation happen. Its README explains which interactions are calls, which are commands and which are events, and why.

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

Fanout is individual `perform_later` calls, one per subscriber. Jobs already accepted are never rolled back when a later subscriber's enqueue fails, and the retry repeats complete fanout under the same event ID. A subscriber must therefore be idempotent, and `event.id` is the key to be idempotent on: it is stable across retries of the publishing execution and across redeliveries of a subscriber's own cause.

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

Inside an opted-in job, an event's ID is derived from a permanent EventRail namespace and the resolved source, executing job class, execution scope, event type, version, and logical identity. The execution scope is the same value the event records as its causation: a regular job's own ID, or, for a subscriber, the ID of the event it is handling. That is what makes identity survive more than one hop: a follow-up event published while handling a redelivered cause derives the ID it derived the first time.

Logical identity is chosen in this order: an explicit event ID (an inbound external event), an explicit `key:` passed to `publish`, the class's `identity_by` attributes, or a singleton marker for the first publication of that type in the execution. Provide an explicit key when neither declared identity nor the singleton default can tell two legitimate publications apart:

```ruby
EventRail.publish(
  Docs::OrderPlaced.new(order_id: "A-1003", total: "5.00", placed_at: Time.now.utc.iso8601),
  key: "adjustment-7"
)
```

Changing `identity_by`, changing `default_source`, or renaming a subscriber class all change the identities that derive from them, so each is a breaking change. Outside a job execution, events receive random IDs.

`occurred_at` is the logical publication time: an explicit timezone-aware value is preserved as the same instant, and otherwise it is the start of the current execution, stable across that execution's retries and never inherited from a cause. Use a persisted domain timestamp when business occurrence time matters. Stored times are UTC at microsecond precision.

`source` identifies a logical producer, not an environment, queue, topic, cluster, or deployment. Any bounded non-empty string is accepted; a stable namespaced value such as `acme.orders` is recommended, and EventRail does no URI parsing.

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

`event_type` and `version` form the durable, language-neutral contract, independent of Ruby class names. A compatible optional addition may keep the same version: an older worker preserves the unknown field as opaque data with no reader and includes it again on export. Removing, renaming, requiring, or retyping a field, changing its meaning, or changing identity requires a new version and a distinct class, and the old class stays registered while messages that reference it can still arrive.

EventRail provides no upcasting and no schema registry.

## Fixed safety limits

| Value | Limit |
| --- | ---: |
| Event, correlation, causation, or boundary identifier | 512 bytes |
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

A relayed event keeps its origin's ID, source, occurrence time, correlation, and extensions; the relaying application's own context extensions are not merged into it, and only a missing causation is filled.

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
