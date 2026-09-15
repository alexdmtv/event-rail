# Changelog

All notable changes to EventRail are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the version is below 1.0 the public API may change in a minor release.

This file tracks the **gem** version only. An event's own `version` is a separate
integer contract declared per event class, and the queue representation carries its own
private format version; neither is derived from the gem version and neither appears
here unless a release changes how they behave.

## [Unreleased]

### Added

- `EventRail::Event` and `EventRail::Data`: immutable, recursively frozen Active Model
  value objects with strict casting that refuses to discard information, an `attributes`
  view of cast values, and a `data` projection that is the single portable written form.
- `EventRail.publish`, returning a frozen `EventRail::Publication` carrying the stamped
  event and the accepted and skipped subscribers.
- `subscribes_to`, discovering subscribers from the conventional `app/events` and
  `app/jobs` roots of the host application and every engine during Rails preparation,
  and validating each one at boot.
- Retry-stable event identity derived as a UUIDv5 over source, executing job class,
  execution scope, event type, version, and logical publication identity, with an
  explicit `key:` and a declarative `identity_by` for selecting that identity.
- `EventRail::JobContext`, an opt-in Active Job concern propagating logical context
  through one reserved key in the job's serialized data.
- `EventRail::Current` and `EventRail.with_context` for establishing and reading
  message, correlation, and causation identifiers, origin time, and string-keyed
  extensions.
- `EventRail::Envelope` and `EventRail::Contract` for crossing a network boundary, with
  the codec and the inbound allowlist owned by the application.
- `EventRail::PortableType`, an opt-in contract for custom attribute types whose
  `portable_examples` are round-tripped through JSON when the attribute is declared.
- Four `ActiveSupport::Notifications` events -- `publish.event_rail`,
  `enqueue_subscriber.event_rail`, `deserialize.event_rail`, and
  `perform_subscriber.event_rail` -- carrying contract, identity, and lineage only.
- A typed error hierarchy rooted at `EventRail::Error`, distinguishing declaration,
  casting, context, serialization, and publication failures.

[Unreleased]: https://github.com/alexdmtv/event-rail/commits/main
