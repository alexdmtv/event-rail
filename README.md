# EventRail

EventRail is an early-stage Rails library for immutable domain events and durable fanout through ordinary Active Job subscribers. It builds on Rails conventions instead of introducing a transport, command bus, dependency-injection container, or replacement job runtime.

EventRail is not ready for production use yet. The public API is still being implemented and validated.

## Requirements

- Ruby 3.3 or newer
- Rails 7.2, 8.0, or 8.1

EventRail depends on Active Support, Active Model, Active Job, and Railties. It does not require Active Record.

## Installation

Add EventRail to the application bundle:

```ruby
gem "event_rail"
```

Then run `bundle install`.

## Events and nested data

Events use Active Model types and validations. Nested objects can be modeled as immutable `EventRail::Data` values, including arrays of typed objects:

```ruby
class Orders::LineItem < EventRail::Data
  attribute :product_id, :string
  attribute :quantity, :integer

  validates :product_id, presence: true
  validates :quantity, numericality: { greater_than: 0 }
end

class Orders::OrderPlaced < EventRail::Event
  event_type "orders.order_placed"
  version 1
  default_source "acme.orders"
  identity_by :order_id

  attribute :order_id, :string
  attribute :line_items, Orders::LineItem, array: true
  attribute :properties

  validates :order_id, presence: true
end

event = Orders::OrderPlaced.new(
  order_id: 123,
  line_items: [{ product_id: 456, quantity: "2" }],
  properties: { "channel" => "web" },
  occurred_at: Time.current,
  extensions: { "tenant" => "north" }
)

event.order_id                  # => "123"
event.line_items.first.quantity # => 2
event.attributes                # complete, string-keyed domain data
event.metadata                  # immutable metadata proposal
```

An untyped attribute accepts only recursively JSON-like values: strings, integers, finite floats, booleans, `nil`, arrays, and string-keyed hashes. Dates, timestamps, decimals, and typed nested structures must use declared Active Model types. Records, GlobalID values, symbols in raw data, arbitrary Ruby objects, non-finite numbers, undeclared attributes, and callable defaults are rejected.

Constructed events, nested data, metadata, and every contained value are recursively immutable. Event payload fields are available through direct readers and `event.attributes`; EventRail deliberately exposes no separate `payload` wrapper.

## Contracts and metadata

`event_type` and `version` form the durable, language-neutral contract identifier. Compatible optional fields can remain at the same version. Breaking shape, type, meaning, nested-data, or identity changes require a new version and a distinct Ruby class.

`default_source` accepts any bounded non-empty application identifier; a namespaced value such as `acme.orders` is recommended. URNs are an interoperability option, not a requirement.

Local construction may provide only `occurred_at` and `extensions`. Event ID, resolved source, correlation, and causation are framework-owned or reconstructed from a trusted inbound envelope. Queue attempts, provider job IDs, transport offsets, and OpenTelemetry propagation are delivery state and never enter durable event metadata.

## Fixed safety limits

EventRail v1 has no global configuration or generated initializer. Metadata uses these fixed byte limits:

| Value | Limit |
| --- | ---: |
| Event, correlation, causation, or boundary identifier | 512 bytes |
| Source | 255 bytes |
| Event type | 255 bytes |
| Extension entries | 32 |
| Extension key | 64 bytes |
| Extension value | 1,024 bytes |
| Total extension key and value bytes | 8,192 bytes |

Extension keys and values must be strings. Framework metadata names, tracing names, and the `eventrail.` prefix are reserved.

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
