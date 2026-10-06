require_relative "module_engine"
require_relative "observability"

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

    # Each environment chooses where structured events go (config.platform.event_log): :json,
    # :text or :none.
    config.platform = ActiveSupport::OrderedOptions.new

    initializer "platform.observability" do |app|
      require_relative "error_subscriber"
      require_relative "event_log"
      require_relative "event_rail_events"

      Rails.error.subscribe(Platform::ErrorSubscriber.new)
      case app.config.platform.event_log
      when :json then Rails.event.subscribe(Platform::EventLog::JsonLines.new)
      when :text then Rails.event.subscribe(Platform::EventLog::Text.new) { |event| event[:name].start_with?("platform.", "event_rail.") }
      when :none then nil
      else raise ArgumentError, "config.platform.event_log names no event log: #{app.config.platform.event_log.inspect}"
      end
    end
  end
end
