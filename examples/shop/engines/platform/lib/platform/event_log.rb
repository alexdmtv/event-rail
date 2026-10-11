module Platform
  # Where structured events (Rails.event) are written; each environment chooses (config.platform.event_log).
  # Both write through Rails.logger, so one logger and one level govern every line. Rails 8.1 emits
  # its own requests and jobs as events too, but registers nowhere to write them.
  module EventLog
    # An event's level is decided here, from what the event is, never by the code that emits it.
    # Everything is information except a failure: an unexpected error at the severity it was
    # reported with, and a job that failed or gave up.
    LEVELS = { "active_job.retry_stopped" => :error, "active_job.discarded" => :error }.freeze
    SEVERITIES = { "error" => :error, "warning" => :warn, "info" => :info }.freeze

    # Rails' event for an error a rescue_from answered: Platform's controller reports every one it
    # answers, as platform.error_reported, which says more.
    SUPERSEDED = %w[ action_controller.rescue_from_handled ].freeze

    # Jobs that run every second, quiet unless they fail, as Rails is about its health check.
    QUIET_JOBS = %w[ Platform::StagedJobRelayJob ].freeze

    def self.level(event)
      payload = event[:payload].is_a?(Hash) ? event[:payload] : {}
      case event[:name]
      when "platform.error_reported" then payload[:expected] ? :info : SEVERITIES.fetch(payload[:severity].to_s, :error)
      when "active_job.completed" then payload[:exception_class] ? :error : :info
      else LEVELS.fetch(event[:name], :info)
      end
    end

    # Decided when writing, not in a subscription filter: from Rails 8.2 a filter sees only the
    # event's name.
    def self.written?(event) = !SUPERSEDED.include?(event[:name]) && !quiet?(event)

    def self.quiet?(event)
      payload = event[:payload].is_a?(Hash) ? event[:payload] : {}
      event[:name].start_with?("active_job.") && QUIET_JOBS.include?(payload[:job_class]) && !payload[:exception_class]
    end

    # The shop's own events: Platform's, EventRail's and each module's, which are named after it.
    # Rails' events have text lines of their own in development.
    def self.own?(name) = name.start_with?("event_rail.", *ModuleEngine.engines.map { |engine| "#{engine.engine_name}." })

    # The event as a hash, for JsonFormatter to write as one JSON object, its request parameters and
    # job arguments redacted.
    class Json
      def emit(event)
        return unless EventLog.written?(event)

        Rails.logger.public_send(EventLog.level(event), event.slice(:name, :tags, :context).merge(payload: Redaction.payload(event[:payload])))
      end
    end

    # What of a request's parameters and a job's arguments reaches the log: only what is known to be
    # safe, so a field added later stays out until someone names it. A deny list
    # (filter_parameters) fails open instead: every new field leaks until it is listed.
    module Redaction
      FILTERED = "[FILTERED]".freeze

      def self.payload(payload)
        return payload unless payload.is_a?(Hash) && (payload.key?(:params) || payload.key?(:arguments))

        payload.merge(payload.slice(:params, :arguments).to_h { |key, value| [ key, key == :params ? params(value) : arguments(value) ] })
      end

      # Every key, so the request's shape shows; a value only under a key named in
      # config.platform.logged_params.
      def self.params(value, key = nil)
        case value
        when Hash then value.to_h { |name, nested| [ name, params(nested, name) ] }
        when Array then value.map { |item| params(item, key) }
        else Rails.configuration.platform.logged_params.include?(key.to_s) ? value : FILTERED
        end
      end

      # A record by its GlobalID, as Rails' own text log writes it; a domain event by its type and
      # ID; anything else filtered.
      def self.arguments(value)
        Array(value).map do |argument|
          case argument
          when EventRail::Event then "#{argument.event_type} #{argument.id}"
          when GlobalID::Identification then argument.to_global_id.to_s
          else FILTERED
          end
        rescue StandardError # a record without an ID has no GlobalID
          FILTERED
        end
      end
    end

    # The event as a short sentence, like Rails' own lines, with the first characters of its flow's
    # correlation ID to follow one flow through the log.
    class Text
      def emit(event)
        payload = event[:payload].is_a?(Hash) ? event[:payload] : {}
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
        line = { time: time.utc.iso8601(6), level: severity, **Observability.current_trace }
        line.merge!(message.is_a?(Hash) ? message : { message: message.is_a?(String) ? message : message.inspect, context: Rails.event.context.presence }.compact)
        "#{encode(line)}\n"
      end

      private
        # Never raises: Logger doesn't rescue its formatter, so the code that logged would fail. A
        # string that isn't valid UTF-8 (a provider's answer, read as binary) is repaired, in keys,
        # values and objects alike; a line that still can't be written says so instead.
        def encode(line)
          ActiveSupport::JSON.encode(line)
        rescue StandardError
          begin
            ActiveSupport::JSON.encode(scrub(line.as_json))
          rescue StandardError => error
            ActiveSupport::JSON.encode(time: line[:time], level: line[:level], message: "unloggable line (#{error.class})")
          end
        end

        def scrub(value)
          case value
          when Hash then value.to_h { |key, nested| [ scrub(key), scrub(nested) ] }
          when Array then value.map { |item| scrub(item) }
          when String then value.dup.force_encoding(Encoding::UTF_8).scrub
          else value
          end
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
