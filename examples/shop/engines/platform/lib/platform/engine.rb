require_relative "module_engine"
require_relative "observability"
require_relative "event_log"
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
    # Request parameters whose values the log may show (Platform::EventLog::Redaction); every other
    # value is filtered. The application names them (config/initializers/filter_parameter_logging.rb).
    config.platform.logged_params = []
    # Which requests come from a caller whose trace context the application continues, another of
    # its own services; every other's is linked to, never joined (Platform::Traces::Edge).
    config.platform.trusted_trace_source = ->(_env) { false }

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
      # Job arguments reach the log only where the JSON log turns them into references; Rails' text
      # job log would write a domain event out whole.
      logs_arguments = app.config.platform.event_log == :json
      ActiveSupport.on_load(:active_job) { self.log_arguments = logs_arguments }
      # Rails turns debug events, such as every SQL query, on in development whatever the log
      # level; one level governs them too.
      app.config.after_initialize { Rails.event.debug_mode = Rails.logger.debug? } unless app.config.platform.event_log == :none
    end

    # Each environment chooses where traces go (config.platform.traces, Platform::Traces). While
    # the application initializes, not after: Action Pack's instrumentation inserts the middleware
    # that opens each request's span only then.
    initializer "platform.traces" do |app|
      Platform::Traces.configure(app.config.platform.traces)
      unless app.config.platform.traces == :none
        app.middleware.insert_before 0, Platform::Traces::Edge # ahead of OpenTelemetry's own
        app.middleware.use Platform::Traces::EdgeLink # inside the request's span
      end
    end
  end
end
