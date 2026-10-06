module Platform
  # Where structured events (Rails.event) are written; each environment chooses (config.platform.event_log).
  # Both write through Rails.logger, so one logger and one level govern every line. Rails 8.1 emits
  # its own requests and jobs as events too, but registers nowhere to write them.
  module EventLog
    LEVELS = { "error" => :error, "warning" => :warn, "info" => :info }.freeze

    # An expected error is an answer, not a problem; an unexpected one keeps its severity.
    def self.level(event)
      payload = event[:payload]
      payload.is_a?(Hash) && payload[:expected] == false ? LEVELS.fetch(payload[:severity].to_s, :error) : :info
    end

    # The event as a hash, for JsonFormatter to write as one JSON object.
    class Json
      def emit(event) = Rails.logger.public_send(EventLog.level(event), event.slice(:name, :payload, :tags, :context))
    end

    # The event as a readable line.
    class Text
      def emit(event)
        details = event[:payload].merge(event[:context]).compact.map { |key, value| "#{key}=#{value}" }.join(" ")
        Rails.logger.public_send(EventLog.level(event), "#{event[:name]} #{details}")
      end
    end

    # Formats every line Rails.logger writes as one JSON object: an event's hash as it is, any other
    # message as text with the request's or job's context.
    class JsonFormatter < ::Logger::Formatter
      def call(severity, time, _progname, message)
        line = { time: time.utc.iso8601(6), level: severity }
        line.merge!(message.is_a?(Hash) ? message : { message: message.is_a?(String) ? message : message.inspect, context: Rails.event.context.presence }.compact)
        "#{ActiveSupport::JSON.encode(line)}\n"
      end
    end

    # The text log subscribers whose lines Rails 8.1 also emits as structured events; with events
    # written as JSON they would say everything twice. Rails' "Started GET" line and Solid Queue's,
    # which have no event, stay.
    def self.detach_text_twins
      ActionController::LogSubscriber.detach_from :action_controller
      ActionDispatch::LogSubscriber.detach_from :action_dispatch
      ActionView::LogSubscriber.detach_from :action_view
      ActiveJob::LogSubscriber.detach_from :active_job
    end
  end
end
