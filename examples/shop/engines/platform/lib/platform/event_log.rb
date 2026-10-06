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

    # The event as a short sentence, like Rails' own lines, with the first characters of its flow's
    # correlation ID to follow one flow through the log.
    class Text
      def emit(event)
        payload = event[:payload]
        flow = (payload[:correlation_id] || event[:context][:correlation_id])&.first(8)
        Rails.logger.public_send(EventLog.level(event), "  #{sentence(event[:name], payload)}#{" [flow #{flow}]" if flow}")
      end

      private
        def sentence(name, payload)
          case name
          when "event_rail.staged" then "EventRail staged #{described(payload)} for #{subscribers(payload[:subscriber_count])}#{took(payload)}"
          when "event_rail.published" then "EventRail published #{described(payload)}#{took(payload)}"
          when "event_rail.subscriber_enqueued" then "EventRail enqueued #{payload[:job_class]} for #{payload[:event_type]}#{took(payload)}"
          when "event_rail.subscriber_performed" then "EventRail #{payload[:job_class]} #{payload[:exception_class] ? "failed on" : "handled"} #{payload[:event_type]}#{took(payload)}#{failure(payload)}"
          when "platform.error_reported" then "#{payload[:expected] ? "Refused" : "Error"}: #{payload[:error_class]} (#{payload[:category] || "unclassified"}): #{payload[:message]}"
          else "#{name} #{payload.compact.map { |key, value| "#{key}=#{value}" }.join(" ")}"
          end
        end

        def described(payload) = "#{payload[:event_type]} v#{payload[:event_version]}"
        def subscribers(count) = count == 1 ? "1 subscriber" : "#{count} subscribers"
        def took(payload) = payload[:duration_ms] ? " (#{payload[:duration_ms]}ms)" : ""
        def failure(payload) = payload[:exception_class] ? ": #{payload[:exception_class]}: #{payload[:exception_message]}" : ""
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
    # Each is required first: it attaches itself when loaded, which a lazily loading environment
    # would otherwise do only later, after this detached nothing.
    def self.detach_text_twins
      require "action_controller/log_subscriber"
      require "action_dispatch/log_subscriber"
      require "action_view/log_subscriber"
      require "active_job/log_subscriber"

      ActionController::LogSubscriber.detach_from :action_controller
      ActionDispatch::LogSubscriber.detach_from :action_dispatch
      ActionView::LogSubscriber.detach_from :action_view
      ActiveJob::LogSubscriber.detach_from :active_job
    end
  end
end
