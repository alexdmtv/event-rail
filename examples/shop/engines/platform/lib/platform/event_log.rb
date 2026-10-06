module Platform
  # Where structured events (Rails.event) are written; each environment chooses one
  # (config.platform.event_log). Rails 8.1 emits its own requests and jobs as events too, but
  # registers nowhere to write them.
  module EventLog
    # One JSON object per line on standard output, for a log platform to parse. Its own logger,
    # because the application log's tags would break the JSON.
    class JsonLines
      def initialize(io = $stdout)
        @logger = ActiveSupport::Logger.new(io)
        @logger.formatter = ->(*, line) { "#{line}\n" }
      end

      def emit(event) = @logger.info(ActiveSupport::JSON.encode(event.slice(:name, :payload, :tags, :context, :timestamp)))
    end

    # A readable line in the application log, at the level what it says deserves: an expected
    # error is an answer, not a problem.
    class Text
      LEVELS = { "error" => :error, "warning" => :warn, "info" => :info }.freeze

      def emit(event)
        payload = event[:payload]
        level = payload[:expected] == false ? LEVELS.fetch(payload[:severity].to_s, :error) : :info
        Rails.logger.public_send(level, "#{event[:name]} #{payload.merge(event[:context]).compact.map { |key, value| "#{key}=#{value}" }.join(" ")}")
      end
    end
  end
end
