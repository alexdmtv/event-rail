# EventRail

EventRail is an early-stage Rails library for immutable domain events and durable fanout through ordinary Active Job subscribers. It builds on Rails conventions instead of introducing a transport, command bus, dependency-injection container, or replacement job runtime.

EventRail is not ready for production use yet. The public API is still being implemented and validated.

## Requirements

- Ruby 3.3 or newer
- Rails 7.2, 8.0, or 8.1

EventRail depends on Active Support, Active Model, Active Job, Railties, and Zeitwerk. It does not require Active Record.

## Installation

```ruby
# doc:illustrative
gem "event_rail"
```

Then run `bundle install`. There is no initializer to generate and nothing to configure: EventRail initializes itself through a Railtie, and every safety limit is a fixed documented constant.

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

Casting refuses to discard information rather than substituting a plausible value. `"abc"` is not `0`, `true` is not `"t"`, a timestamp needs an explicit offset, and a date attribute will not silently drop a time of day. An untyped attribute accepts only recursively JSON-like values — strings, integers, finite floats, booleans, `nil`, arrays, string-keyed hashes — bounded in nesting depth and forbidden from using the `_aj_` prefix Active Job reserves in its own argument encoding. Records, GlobalID values, arbitrary Ruby objects, non-finite numbers, undeclared attributes, and callable defaults are rejected.

Constructed events, nested data, metadata, and every contained value are recursively immutable. Two events of one class with equal payload and equal metadata are equal values, which is what lets `assert_enqueued_with(args: [event])` match a published event.

## Publishing

```ruby
module Docs
  class OnOrderPlacedJob < ApplicationJob
    subscribes_to OrderPlaced

    def perform(event)
      Rails.logger.info("charging #{event.order_id} idempotently on #{event.id}")
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

Subscribers are discovered from the conventional `app/events` and `app/jobs` roots of the host application and every engine, during Rails preparation. There is no registration API, no initializer, and no registry to query.

`subscribes_to` is exact and not inherited: a subclass of a subscriber is a different job and receives nothing. A subscriber must define its own `perform` taking exactly one required positional event parameter, must not have subclasses, and must include `EventRail::JobContext`. Each of those is checked during preparation, so a mistake fails the boot that introduced it rather than the first publication.

### At-least-once delivery, and what that means for subscribers

Fanout is individual `perform_later` calls, one per subscriber. Jobs already accepted are never rolled back when a later subscriber's enqueue fails, and the retry repeats complete fanout under the same event ID. A subscriber must therefore be idempotent, and `event.id` is the key to be idempotent on: it is stable across retries of the publishing execution and across redeliveries of a subscriber's own cause.

No ordering is promised, between subscribers or between events.

Retries, backoff, discarding, and dead-letter handling stay where they already are: each subscriber's own Active Job configuration and the configured queue adapter. EventRail adds no retry policy of its own and no failure queue.

### Publishing inside a database transaction

Don't. Publication raises `EventRail::TransactionalPublicationError` when a transaction is open, in every environment, and the fix is to publish after the transaction commits.

Both queue deferral settings are wrong inside a transaction, in opposite directions. With `enqueue_after_transaction_commit` on, the enqueue is deferred past the point where its failure can be reported, so a publication that silently enqueued nothing looks successful. With it off, the enqueue announces a fact that a rollback then contradicts. The check is on the open transaction itself, so it does not depend on the setting — or on Active Record being present at all.

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

Inside an opted-in job, an event's ID is derived from a permanent EventRail namespace and the resolved source, executing job class, execution scope, event type, version, and logical identity. The execution scope is the same value the event records as its causation: a regular job's own ID, or, for a subscriber, the ID of the event it is handling. That is what makes identity survive more than one hop — a follow-up event published while handling a redelivered cause derives the ID it derived the first time.

Logical identity is chosen in this order: an explicit event ID (an inbound external event), an explicit `key:` passed to `publish`, the class's `identity_by` attributes, or a singleton marker for the first publication of that type in the execution. Provide an explicit key when neither declared identity nor the singleton default can tell two legitimate publications apart:

```ruby
EventRail.publish(
  Docs::OrderPlaced.new(order_id: "A-1003", total: "5.00", placed_at: Time.now.utc.iso8601),
  key: "adjustment-7"
)
```

Changing `identity_by`, changing `default_source`, or renaming a subscriber class all change the identities that derive from them, so each is a breaking change. Outside a job execution, events receive random IDs.

`occurred_at` is the logical publication time: an explicit timezone-aware value is preserved as the same instant, and otherwise it is the start of the current execution, stable across that execution's retries and never inherited from a cause. Use a persisted domain timestamp when business occurrence time matters. Stored times are UTC at microsecond precision.

`source` identifies a logical producer — not an environment, queue, topic, cluster, or deployment. Any bounded non-empty string is accepted; a stable namespaced value such as `acme.orders` is recommended, and EventRail does no URI parsing.

## Logical context

Application-owned ingress code establishes context; EventRail ships no HTTP middleware and no controller concern, and harvests nothing from headers, Rails current state, or tracing baggage.

```ruby
EventRail.with_context(message_id: "req-abc", extensions: { "tenant" => "north" }) do
  EventRail.publish(Docs::OrderPlaced.new(order_id: "A-1004", total: "7.00", placed_at: Time.now.utc.iso8601))
end
```

A nested scope inherits lineage and may add extensions or repeat identical values; replacing an inherited identifier, origin time, or extension value fails rather than rewriting the lineage of a flow already in progress.

Context extensions are durable baggage: opted-in child jobs carry them, and published events merge them with event-local extensions, rejecting conflicting values. They are not the place for domain data — that belongs in declared attributes.

Lineage is isolated per unit of concurrent execution through `ActiveSupport::IsolatedExecutionState`, which defaults to thread isolation. **A host running fiber-per-request must set `config.active_support.isolation_level = :fiber`**, or lineage will be shared between concurrent requests. EventRail documents that requirement rather than claiming an isolation it cannot provide.

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

assert_enqueued_with(job: Docs::OnOrderPlacedJob, args: [ publication.event ])
perform_enqueued_jobs
```

`assert_enqueued_with(args:)` works because events are value objects. For observability assertions, subscribe to the notifications below. EventRail ships no assertion library, observer, or contract-test helper.

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

Rolling back reverses that: a rollback is safe only to a release that can still read what the newer release wrote. A change to how an individual value is written is a different matter — that encoding is shared with the public envelope, so it is a breaking public change rather than a private format bump.

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
