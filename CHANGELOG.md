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

### Changed

- **Breaking: an event with declared identity derives its ID from the fact, not from the
  job that publishes it.** With `identity_by` or `identity:`, the ID now comes from the
  event's source, event type and identity only: not the job class, the job's ID, the
  execution or the schema version. The same fact has one ID wherever and however often it
  is published, in a controller or in any job, and in every version of its event type.
  Previously a caller that ran twice enqueued a new job with a new ID and published the same
  fact under a new event ID.
- **Breaking: `publish(event, key:)` is now `publish(event, identity:)`.** A key used to be
  scoped to one job; an identity names a fact across every job. `key:` raises with
  directions, and `identity:` is refused for a class that declares `identity_by`. An explicit
  identity derives the same ID as a single string `identity_by` attribute with the same value.
- **Breaking: every derived ID changes.** The derivation has a new namespace and separate,
  documented rules for declared facts and for executions, pinned by vectors published in the
  README so other implementations can reproduce them. Strings are hashed as UTF-8 and invalid
  UTF-8 is refused.
- **Breaking: random IDs are UUIDv7**, time-ordered, for events without declared identity
  published outside a job. Derived IDs remain UUIDv5.
- An event without declared identity published by a subscriber derives its ID from the
  handled event's source as well as its ID, so causes from two producers that share an ID are
  scoped apart.
- The duplicate check within one execution includes the source, so one job can publish the
  same fact for two producers, and relay two events that share an ID from different sources.
- A relayed event keeps its lineage as it arrived: an absent causation is no longer filled
  from the relaying context. A relay retried with a different payload, occurrence time or
  extensions is refused, as a local retry is.
- One publication record per `(source, type, version, id)` within an execution: publishing
  the stamped event of a failed local publication, for instance to recover from an
  `EnqueueError`, is its retry, and publishing it after success is a duplicate. A relayed ID
  is compared as opaque bytes, so an ID that is not valid UTF-8 relays as before.
- **Breaking: a declared identity attribute cannot be an empty string**, as it cannot be nil:
  every blank event would otherwise be one fact.
- `EventRail.with_context` opened inside a running job keeps the job's execution, so an
  undeclared event published in the block keeps its retry-stable ID and its duplicate check;
  it used to get a random ID.
- Versioning: every version of an event type keeps its declared identity values; changing
  what an event identifies needs a new event type, not a new version.

### Added

- `publish(event, source:)` publishes a locally built event on behalf of another producer,
  such as an inbound webhook; relaying an event under a different source than it carries is
  refused.

### Upgrading

- Audit every `identity_by` and every former `key:` before upgrading. A value that was safe
  within one job, such as a line number or a product ID for a fact that recurs, now names one
  fact across every job and would merge distinct facts silently. Identity must name the
  occurrence, not the thing it is about.
- IDs derived before and after the upgrade differ. A publication retried across the deploy, a
  delayed job, a backfill or a dead-letter redelivery can deliver a fact again under a new ID;
  subscribers that also deduplicate on a business key are unaffected. Draining publishing jobs
  before deploying narrows the window.

## [0.3.0] - 2026-09-21

### Changed

- **`subscribes_to` now raises `EventRail::DeclarationError` when the event class it names
  declares neither `event_type` nor `version`**, at the declaration itself. Previously such
  a subscription was accepted and then never fired: publication matches subscribers by exact
  event class, so a concrete subclass never reached the base's registration, and the class
  without a contract could not be constructed to be published on its own. Because neither
  declaration is inherited, this covers a shared abstract base such as `ApplicationEvent`
  and equally a subclass of a concrete event that adds nothing of its own. Subscribe to each
  concrete event class instead.

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

[Unreleased]: https://github.com/alexdmtv/event-rail/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/alexdmtv/event-rail/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/alexdmtv/event-rail/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/alexdmtv/event-rail/releases/tag/v0.1.0
