require_relative "lib/event_rail/version"

Gem::Specification.new do |spec|
  spec.name = "event_rail"
  spec.version = EventRail::VERSION
  spec.authors = [ "Alex Dmitriev" ]
  spec.email = [ "alexey.dmitriev6238@gmail.com" ]
  spec.homepage = "https://github.com/alexdmtv/event-rail"
  spec.summary = "Typed, durable event fanout through ordinary Active Job subscribers."
  spec.description = "EventRail adds immutable domain events, stable, fact-derived identity, logical context propagation, and Rails-native durable fanout without replacing Active Job or its queue adapter."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*.rb",
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    "MIT-LICENSE",
    "README.md",
    "SECURITY.md"
  ]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "activejob", ">= 7.2", "< 9"
  spec.add_dependency "activemodel", ">= 7.2", "< 9"
  spec.add_dependency "activesupport", ">= 7.2", "< 9"
  spec.add_dependency "railties", ">= 7.2", "< 9"
  # Subscriber discovery eager-loads the conventional app/events and app/jobs roots
  # through Zeitwerk::Loader#eager_load_dir, which arrived in 2.6.2. Railties allows
  # ~> 2.6, so the floor has to be stated here rather than inherited.
  spec.add_dependency "zeitwerk", ">= 2.6.2", "< 4"
end
