require "bigdecimal"
require "date"

module EventRail
  module Internal
    module PortableValue
      module_function

      RAW_SCALARS = [ NilClass, TrueClass, FalseClass, String, Integer, Float ].freeze
      TYPED_SCALARS = [ BigDecimal, Date, DateTime, Time ].freeze

      def raw(value, path: "value", depth: 0)
        reject_record!(value, path: path)

        case value
        when *RAW_SCALARS
          freeze_scalar(value, path: path)
        when Array
          check_depth!(depth, path: path)
          value.each_with_index.map do |item, index|
            raw(item, path: "#{path}[#{index}]", depth: depth + 1)
          end.freeze
        when Hash
          check_depth!(depth, path: path)
          value.each_with_object({}) do |(key, item), result|
            unless key.is_a?(String)
              raise CastingError, "#{path} must use string hash keys; got #{key.inspect}"
            end
            if key.start_with?(Limits::ACTIVE_JOB_RESERVED_KEY_PREFIX)
              raise CastingError,
                "#{path} key #{key.inspect} uses the #{Limits::ACTIVE_JOB_RESERVED_KEY_PREFIX.inspect} " \
                "prefix Active Job reserves in its argument encoding"
            end

            frozen_key = key.dup.freeze
            result[frozen_key] = raw(item, path: "#{path}.#{key}", depth: depth + 1)
          end.freeze
        else
          raise CastingError, "#{path} contains unsupported #{value.class}"
        end
      end

      def typed(value, path: "value")
        reject_record!(value, path: path)

        case value
        when *RAW_SCALARS, *TYPED_SCALARS
          freeze_scalar(value, path: path)
        when Array, Hash
          raw(value, path: path)
        else
          raise CastingError, "#{path} cast to unsupported #{value.class}"
        end
      end

      # A written value has crossed no boundary yet, so this is a structural check
      # of what a JSON encoder can carry rather than a trust decision.
      def json_primitive?(value)
        case value
        when *RAW_SCALARS
          !value.is_a?(Float) || value.finite?
        when Array
          value.all? { |item| json_primitive?(item) }
        when Hash
          value.all? { |key, item| key.is_a?(String) && json_primitive?(item) }
        else
          false
        end
      end

      def literal_default?(value)
        case value
        when Proc, Method
          false
        when Array
          value.all? { |item| literal_default?(item) }
        when Hash
          value.all? { |key, item| literal_default?(key) && literal_default?(item) }
        else
          !value.respond_to?(:call)
        end
      end

      def reject_record!(value, path: "value")
        global_id_value = value.class.name == "GlobalID" && value.respond_to?(:app) && value.respond_to?(:model_id)
        return unless value.respond_to?(:to_global_id) || global_id_value

        raise CastingError, "#{path} cannot contain records or GlobalID values"
      end

      def check_depth!(depth, path:)
        return if depth < Limits::MAX_RAW_DEPTH

        raise CastingError, "#{path} exceeds the maximum nesting depth of #{Limits::MAX_RAW_DEPTH}"
      end
      private_class_method :check_depth!

      def freeze_scalar(value, path:)
        if value.is_a?(Numeric) && value.respond_to?(:finite?) && !value.finite?
          raise CastingError, "#{path} must contain a finite number"
        end

        value.is_a?(String) ? value.dup.freeze : value.freeze
      end
      private_class_method :freeze_scalar
    end
  end
end
