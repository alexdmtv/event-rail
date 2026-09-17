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

## [0.2.0] - 2026-09-17

### Added

- `EventRail::TestHelper`, loaded by an explicit `require "event_rail/test_helper"` and not
  by requiring the library. `EventRail::TestHelper.declare` opens a window in which event
  contracts and subscriptions may be declared after application preparation has sealed the
  registry, and `with_subscribers` activates a declared fixture subscriber for the duration
  of one block, restoring the previous registry afterwards. Contracts declared in a window
  go live when it closes; subscribers stay dormant until activated, so a fixture cannot fan
  out in a later test that never mentions it.
- `config.event_rail.roots`, defaulting to `%w[app/events app/jobs]` and appendable, naming
  the directories discovery scans. Each entry is matched as a path suffix against the main
  autoloader's roots, so one entry covers the host application and every engine. A
  configured root beyond the default that is not an autoload root fails preparation with the
  new `EventRail::ConfigurationError`; a default root the application has not created is
  skipped.

### Changed

- **A concrete `EventRail::Event` subclass that declares `event_type` or `version` after
  preparation now raises `EventRail::DeclarationError` at the declaration**, the same rule
  subscriptions have always followed. Previously such a class was silently absent from the
  contract index: it published cleanly, serialized cleanly, and failed only when a worker
  tried to reconstruct it, with `UnknownEventTypeError`. Move the class under `app/events`,
  add its root to `config.event_rail.roots`, or -- for a test fixture -- declare it inside
  `EventRail::TestHelper.declare`. Abstract bases and classes never assigned to a constant
  are unaffected.
- A subscription declared on a class with no name now raises where it is declared. Active
  Job cannot enqueue a job it cannot name, so this was never a working configuration; it was
  previously dropped from the registry without comment.
- Both late-declaration messages now name the declaration's own file and line, state that
  discovery runs before `eager_load!` so `config.eager_load_paths` alone is never enough,
  and offer both remedies. The advice to load such code from an autoload-once path is gone
  as general guidance: it never applied to reloadable application code.

### Fixed

- A declaration arriving between a reload's constant unload and the registry rebuild is no
  longer rejected as late. Rails deletes constants before running prepare callbacks and
  nothing cleared the snapshot in between, so that window was indistinguishable from a
  sealed registry -- reachable by any prepare callback ordered ahead of EventRail's,
  including one belonging to a gem that loads earlier in the Gemfile.

## [0.1.0] - 2026-09-15

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

[Unreleased]: https://github.com/alexdmtv/event-rail/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/alexdmtv/event-rail/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/alexdmtv/event-rail/releases/tag/v0.1.0
