require "active_model/type"

module EventRail
  module Internal
    module Types
      Definition = ::Data.define(:kind, :type, :array)

      class Raw < ActiveModel::Type::Value
        def cast(value)
          PortableValue.raw(value)
        end
      end

      class Scalar < ActiveModel::Type::Value
        def initialize(delegate)
          @delegate = delegate
        end

        def cast(value)
          return if value.nil?

          PortableValue.reject_record!(value)
          casted = @delegate.cast(value)
          PortableValue.typed(casted)
        end

        def type
          @delegate.type
        end
      end

      class NestedData < ActiveModel::Type::Value
        attr_reader :data_class

        def initialize(data_class)
          @data_class = data_class
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
        attr_reader :item_type

        def initialize(item_type)
          @item_type = item_type
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

      def resolve(cast_type, array:, options:)
        type, kind = if cast_type.nil?
          [ Raw.new, :raw ]
        elsif cast_type.is_a?(Class) && cast_type < EventRail::Data
          [ NestedData.new(cast_type), :data ]
        else
          delegate = if cast_type.is_a?(ActiveModel::Type::Value)
            cast_type
          else
            ActiveModel::Type.lookup(cast_type, **options)
          end
          [ Scalar.new(delegate), delegate.type ]
        end

        resolved = array ? ArrayOf.new(type) : type
        [ resolved, Definition.new(kind: kind, type: resolved, array: array) ]
      rescue ArgumentError => error
        raise DeclarationError, error.message
      end
    end
  end
end
