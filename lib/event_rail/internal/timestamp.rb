require "active_model/type"

module EventRail
  module Internal
    # One normalization for every instant EventRail stores, whether it arrives as
    # metadata or as a declared attribute: an explicit offset is required, an offset
    # outside the valid range is refused rather than quietly dropped, and the result
    # is UTC at microsecond precision.
    module Timestamp
      module_function

      def cast(value, field: "timestamp")
        normalize(value, field: field, error: InvalidMetadata)
      end

      def normalize(value, field: "timestamp", error: InvalidMetadata)
        return if value.nil?

        check_offset!(value, field: field, error: error)

        casted = ActiveModel::Type.lookup(:datetime).cast(value)
        raise error, "#{field} is invalid" unless casted

        microseconds = (epoch_seconds(casted) * 1_000_000).floor
        Time.at(Rational(microseconds, 1_000_000)).utc.freeze
      rescue Error
        raise
      rescue ArgumentError, TypeError, RangeError => cause
        raise error, "#{field} is invalid: #{cause.message}"
      end

      # Rails' :datetime cast returns a Time for a string and passes a Time,
      # DateTime, or TimeWithZone through unchanged. Every one of those answers
      # to_r except DateTime, whose only conversion is the to_time path Rails 7.2
      # deprecates, so DateTime is reduced through its own formatted epoch instead.
      def epoch_seconds(value)
        case value
        when DateTime then Rational(value.strftime("%s")) + value.sec_fraction
        else value.to_r
        end
      end
      private_class_method :epoch_seconds

      # Ruby parses an out-of-range offset into a zone string with no usable offset,
      # and Rails then treats the value as UTC. That silently records a different
      # instant than the caller wrote, so the zone-without-offset case is refused.
      def check_offset!(value, field:, error:)
        case value
        when Time, DateTime
          nil
        when String
          parsed = begin
            Date._parse(value)
          rescue ArgumentError, TypeError
            raise error, "#{field} is invalid"
          end

          if parsed[:offset].nil?
            if parsed[:zone]
              raise error, "#{field} has an offset outside the valid range: #{parsed[:zone].inspect}"
            end

            raise error, "#{field} must include an explicit UTC offset"
          end
        when Date
          raise error, "#{field} must include a time of day and an explicit UTC offset"
        else
          unless value.respond_to?(:time_zone) && !value.time_zone.nil?
            raise error, "#{field} must include an explicit UTC offset"
          end
        end
      end
      private_class_method :check_offset!
    end
  end
end
