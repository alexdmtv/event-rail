require "active_model/type"

module EventRail
  module Internal
    module Timestamp
      module_function

      ZONE_SUFFIX = /(?:Z|[+-]\d{2}:?\d{2})\z/i

      def cast(value, field: "timestamp")
        return if value.nil?

        unless timezone_aware?(value)
          raise InvalidMetadata, "#{field} must include a timezone"
        end

        casted = ActiveModel::Type.lookup(:datetime).cast(value)
        raise InvalidMetadata, "#{field} is invalid" unless casted

        microseconds = (casted.to_time.to_r * 1_000_000).floor
        Time.at(Rational(microseconds, 1_000_000)).utc.freeze
      rescue InvalidMetadata
        raise
      rescue ArgumentError, TypeError => error
        raise InvalidMetadata, "#{field} is invalid: #{error.message}"
      end

      def timezone_aware?(value)
        case value
        when Time, DateTime
          true
        when String
          value.match?(ZONE_SUFFIX)
        else
          value.respond_to?(:time_zone) && !value.time_zone.nil?
        end
      end
      private_class_method :timezone_aware?
    end
  end
end
