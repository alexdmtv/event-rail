require "bigdecimal"
require "date"

module EventRail
  module Internal
    module PortableValue
      module_function

      RAW_SCALARS = [ NilClass, TrueClass, FalseClass, String, Integer, Float ].freeze
      TYPED_SCALARS = [ BigDecimal, Date, DateTime, Time ].freeze

      def raw(value, path: "value")
        reject_record!(value, path: path)

        case value
        when *RAW_SCALARS
          freeze_scalar(value, path: path)
        when Array
          value.each_with_index.map { |item, index| raw(item, path: "#{path}[#{index}]") }.freeze
        when Hash
          value.each_with_object({}) do |(key, item), result|
            unless key.is_a?(String)
              raise CastingError, "#{path} must use string hash keys; got #{key.inspect}"
            end

            frozen_key = key.dup.freeze
            result[frozen_key] = raw(item, path: "#{path}.#{key}")
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

      def export(value, path: "value")
        case value
        when EventRail::Data
          value.attributes
        when Array
          value.each_with_index.map { |item, index| export(item, path: "#{path}[#{index}]") }.freeze
        when Hash
          value.each_with_object({}) do |(key, item), result|
            unless key.is_a?(String)
              raise CastingError, "#{path} must use string hash keys; got #{key.inspect}"
            end

            result[key.dup.freeze] = export(item, path: "#{path}.#{key}")
          end.freeze
        else
          typed(value, path: path)
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
