require "active_model/type"
require "bigdecimal"

module EventRail
  module Internal
    module Types
      # Every attribute type owns the translation between its cast value and its
      # portable form, in both directions. Canonicalization therefore happens once,
      # during casting, instead of being rediscovered by a second generic tree walk
      # after validation. `from_portable` is the wire-input direction the private
      # Active Job serializer and external codecs read through.
      module Portable
        # True when a cast value is already its own portable form, so exporting it
        # is identity rather than a structural conversion.
        def portable_identity?
          true
        end

        def to_portable(value)
          value
        end

        def from_portable(value)
          cast(value)
        end
      end

      class Raw < ActiveModel::Type::Value
        include Portable

        def cast(value)
          PortableValue.raw(value)
        end
      end

      # Active Model inherits form-oriented coercion that turns unusable input into a
      # plausible value: "abc" becomes 0, "12abc" becomes 12, and anything outside a
      # known false list becomes true. A durable fact must not record a fabricated
      # value that no validation can distinguish from a supplied one, so casting is
      # gated on losslessness. The rule is about discarded information rather than
      # trust, so it holds identically for local construction and for wire input:
      # parsing "2026-09-01" into a date stays legal.
      module Lossless
        BOOLEAN_STRINGS = %w[true false t f 1 0 on off].freeze
        BOOLEAN_INTEGERS = [ 0, 1 ].freeze

        module_function

        def check!(value, type, path:)
          case type
          when :integer then check_integer!(value, path)
          when :float then check_float!(value, path)
          when :decimal then check_decimal!(value, path)
          when :boolean then check_boolean!(value, path)
          end
        end

        def check_integer!(value, path)
          case value
          when Integer then nil
          when String then reject!(path, value, "integer") if Integer(value, exception: false).nil?
          when Numeric
            reject!(path, value, "integer") unless value.finite? && value.to_i == value
          else
            reject!(path, value, "integer")
          end
        end

        def check_float!(value, path)
          case value
          when Numeric then nil
          when String then reject!(path, value, "float") if Float(value, exception: false).nil?
          else reject!(path, value, "float")
          end
        end

        def check_decimal!(value, path)
          case value
          when Numeric then nil
          when String then reject!(path, value, "decimal") if BigDecimal(value, exception: false).nil?
          else reject!(path, value, "decimal")
          end
        end

        def check_boolean!(value, path)
          case value
          when true, false then nil
          when String then reject!(path, value, "boolean") unless BOOLEAN_STRINGS.include?(value.downcase)
          when Integer then reject!(path, value, "boolean") unless BOOLEAN_INTEGERS.include?(value)
          else reject!(path, value, "boolean")
          end
        end

        def reject!(path, value, label)
          raise CastingError, "#{path} cannot represent #{value.inspect} as #{label} without discarding information"
        end
      end

      class Scalar < ActiveModel::Type::Value
        include Portable

        def initialize(delegate)
          @delegate = delegate
        end

        def cast(value)
          return if value.nil?

          PortableValue.reject_record!(value)
          Lossless.check!(value, @delegate.type, path: "value")
          casted = @delegate.cast(value)
          if casted.nil?
            raise CastingError, "value cannot represent #{value.inspect} as #{@delegate.type} without discarding information"
          end

          PortableValue.typed(casted)
        end

        def type
          @delegate.type
        end
      end

      class NestedData < ActiveModel::Type::Value
        include Portable

        attr_reader :data_class

        def initialize(data_class)
          @data_class = data_class
        end

        # Nested Ruby class names never cross a boundary: the record's own canonical
        # attributes already are its portable tree.
        def portable_identity?
          false
        end

        def to_portable(value)
          value&.attributes
        end

        def cast(value)
          return if value.nil?
          return value if value.instance_of?(data_class)

          unless value.is_a?(Hash)
            raise CastingError, "nested #{data_class} must be constructed from a hash"
          end

          data_class.new(value)
        end

        def type
          :event_rail_data
        end
      end

      class ArrayOf < ActiveModel::Type::Value
        include Portable

        attr_reader :item_type

        def initialize(item_type)
          @item_type = item_type
        end

        def portable_identity?
          item_type.portable_identity?
        end

        def to_portable(value)
          return value if value.nil? || portable_identity?

          value.map { |item| item_type.to_portable(item) }.freeze
        end

        def from_portable(value)
          cast(value)
        end

        def cast(value)
          return if value.nil?

          unless value.is_a?(Array)
            raise CastingError, "array attribute must be constructed from an array"
          end

          value.each_with_index.map do |item, index|
            item_type.cast(item)
          rescue Error => error
            contextual = if error.respond_to?(:validation_errors)
              error.class.new(
                "array item #{index}: #{error.message}",
                validation_errors: error.validation_errors
              )
            else
              error.class.new("array item #{index}: #{error.message}")
            end

            raise contextual, cause: error
          end.freeze
        end

        def type
          :event_rail_array
        end
      end

      module_function

      # Active Model already keeps a per-class memoized map of attribute name to
      # type, invalidated on redeclaration, so the resolved type is the only thing
      # worth returning: it is the whole definition.
      def resolve(cast_type, array:, options:)
        type = if cast_type.nil?
          Raw.new
        elsif cast_type.is_a?(Class) && cast_type < EventRail::Data
          NestedData.new(cast_type)
        else
          delegate = if cast_type.is_a?(ActiveModel::Type::Value)
            cast_type
          else
            ActiveModel::Type.lookup(cast_type, **options)
          end
          Scalar.new(delegate)
        end

        array ? ArrayOf.new(type) : type
      rescue ArgumentError => error
        raise DeclarationError, error.message
      end
    end
  end
end
