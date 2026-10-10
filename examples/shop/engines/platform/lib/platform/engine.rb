require_relative "module_engine"
require_relative "observability"
require_relative "event_log"
require_relative "metrics"
require_relative "traces"

module Platform
  class Engine < ::Rails::Engine
    extend ModuleEngine

    isolate_namespace Platform
    share_migrations

    initializer "platform.problem_details" do |app|
      require_relative "exceptions_app"
      Mime::Type.register "application/problem+json", :problem
      app.config.exceptions_app = Platform::ExceptionsApp
    end

    # Each environment chooses how structured events are logged (config.platform.event_log): :json,
    # with Rails.logger formatting every line as JSON (Platform::EventLog::JsonFormatter); :text;
    # or :none.
    config.platform = ActiveSupport::OrderedOptions.new

    initializer "platform.observability" do |app|
      require_relative "error_subscriber"
      require_relative "event_rail_events"

      Rails.error.subscribe(Platform::ErrorSubscriber.new)
      case app.config.platform.event_log
      when :json
        Rails.event.subscribe(Platform::EventLog::Json.new)
        app.config.after_initialize { Platform::EventLog.detach_text_twins }
      when :text then Rails.event.subscribe(Platform::EventLog::Text.new) { |event| Platform::EventLog.own?(event[:name]) }
      when :none then nil
      else raise ArgumentError, "config.platform.event_log names no event log: #{app.config.platform.event_log.inspect}"
      end
      # Rails turns debug events, such as every SQL query, on in development whatever the log
      # level; one level governs them too.
      app.config.after_initialize { Rails.event.debug_mode = Rails.logger.debug? } unless app.config.platform.event_log == :none
    end

    # Each environment chooses where metrics go (config.platform.metrics): :none; :prometheus,
    # served on /metrics for Prometheus to scrape; or :test, which records them for tests to read.
    # Another monitoring system's Yabeda adapter (yabeda-datadog) would be another choice here.
    initializer "platform.metrics" do |app|
      case app.config.platform.metrics
      when :none then nil
      when :prometheus then require "yabeda/prometheus" # registers its adapter
      when :test
        require "yabeda/test_adapter"
        Yabeda.register_adapter(:test, Yabeda::TestAdapter.instance)
      else raise ArgumentError, "config.platform.metrics names no metrics adapter: #{app.config.platform.metrics.inspect}"
      end
      Platform::Metrics.guard_adapters
      Rails.event.subscribe(Platform::Metrics::EventCounts.new) { |event| Platform::Metrics::EventCounts::NAMES.include?(event[:name]) }
    end

    # Each environment chooses where traces go (config.platform.traces, Platform::Traces). While
    # the application initializes, not after: Action Pack's instrumentation inserts the middleware
    # that opens each request's span only then.
    initializer "platform.traces" do |app|
      Platform::Traces.configure(app.config.platform.traces)
    end
  end
end
