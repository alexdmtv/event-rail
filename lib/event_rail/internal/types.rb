require "active_model/type"
require "bigdecimal"
require "date"
require "json"

module EventRail
  module Internal
    module Types
      # Every attribute type owns the translation between its cast value and its
      # written form, in both directions, under Active Model's own names. The written
      # form is always a JSON primitive: Active Job does not recurse into a custom
      # serializer's output, so anything else reaches the queue adapter raw.
      #
      # The walk is type-directed rather than shape-guessing. `deserialize` is the
      # trusted wire-input direction the private Active Job serializer and external
      # codecs read through; `cast` stays the strict door for local construction.

      # Written forms for the scalar types EventRail supports. Each codec states the
      # cast classes it accepts so a delegate that reports a familiar `type` while
      # casting to something else fails during construction rather than writing a
      # value its own reader cannot read back.
      class ScalarCodec
        attr_reader :classes

        def initialize(classes:, write:, read:)
          @classes = classes.freeze
          @write = write
          @read = read
          freeze
        end

        def accepts?(value)
          classes.any? { |klass| value.instance_of?(klass) }
        end

        def write(value)
          @write.call(value)
        end

        def read(value)
          @read.call(value)
        end
      end

      UTC_MICROSECOND_FORMAT = "%Y-%m-%dT%H:%M:%S.%6NZ".freeze

      SCALAR_CODECS = {
        string: ScalarCodec.new(
          classes: [ String ],
          write: ->(value) { value },
          read: ->(value) { value }
        ),
        integer: ScalarCodec.new(
          classes: [ Integer ],
          write: ->(value) { value },
          read: ->(value) { value }
        ),
        float: ScalarCodec.new(
          classes: [ Float ],
          write: ->(value) { value },
          read: ->(value) { value }
        ),
        boolean: ScalarCodec.new(
          classes: [ TrueClass, FalseClass ],
          write: ->(value) { value },
          read: ->(value) { value }
        ),
        decimal: ScalarCodec.new(
          classes: [ BigDecimal ],
          write: ->(value) { value.to_s("F").freeze },
          read: ->(value) { value }
        ),
        date: ScalarCodec.new(
          classes: [ Date ],
          write: ->(value) { value.iso8601.freeze },
          read: ->(value) { value }
        ),
        datetime: ScalarCodec.new(
          classes: [ Time ],
          write: ->(value) { value.utc.strftime(UTC_MICROSECOND_FORMAT).freeze },
          read: ->(value) { value }
        )
      }.freeze

      # Rails' :time is a time-of-day type: casting an instant through it discards
      # the date. A durable fact cannot record that, and :datetime is the type that
      # keeps the whole instant.
      REDIRECTED_TYPES = { time: :datetime }.freeze

      module Portable
        def serialize(value)
          value
        end

        def deserialize(value)
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
      # plausible value: "abc" becomes 0, "12abc" becomes 12, true becomes "t", and
      # anything outside a known false list becomes true. A durable fact must not
      # record a fabricated value that no validation can distinguish from a supplied
      # one, so casting is gated on losslessness. The rule is about discarded
      # information rather than trust, so it holds identically for local construction
      # and for wire input: parsing "2026-09-01" into a date stays legal.
      module Lossless
        BOOLEAN_STRINGS = %w[true false t f 1 0 on off].freeze
        BOOLEAN_INTEGERS = [ 0, 1 ].freeze
        ISO_DATE = /\A-?\d{4,}-\d{2}-\d{2}\z/

        module_function

        def check!(value, type, path:)
          case type
          when :integer then check_integer!(value, path)
          when :float then check_float!(value, path)
          when :decimal then check_decimal!(value, path)
          when :boolean then check_boolean!(value, path)
          when :string then check_string!(value, path)
          when :date then check_date!(value, path)
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

        # Rails renders any object into a string attribute, so a boolean becomes "t"
        # and an integer becomes "5". Neither is recoverable, and neither is what the
        # caller meant to record.
        def check_string!(value, path)
          reject!(path, value, "string") unless value.is_a?(String)
        end

        # Casting an instant to a date discards its time of day, and which date it
        # discards to depends on an offset the caller may not have stated. A date
        # attribute therefore takes a date, spelled as a Date or as a complete ISO
        # date, and refuses anything carrying a time.
        def check_date!(value, path)
          return if value.instance_of?(Date)
          return if value.is_a?(String) && value.match?(ISO_DATE)

          if value.is_a?(String) || value.is_a?(Time) || value.is_a?(DateTime)
            raise CastingError,
              "#{path} cannot represent #{value.inspect} as a date without discarding its time of day; " \
              "supply a Date or a YYYY-MM-DD string"
          end

          reject!(path, value, "date")
        end

        def reject!(path, value, label)
          raise CastingError, "#{path} cannot represent #{value.inspect} as #{label} without discarding information"
        end
      end

      class Scalar < ActiveModel::Type::Value
        attr_reader :delegate

        def initialize(delegate)
          @delegate = delegate
          @codec = SCALAR_CODECS[delegate.type]
          freeze
        end

        def cast(value)
          return if value.nil?

          PortableValue.reject_record!(value)
          Lossless.check!(value, type, path: "value")

          casted = if type == :datetime
            Timestamp.normalize(value, field: "value", error: CastingError)
          else
            @delegate.cast(value)
          end

          if casted.nil?
            raise CastingError, "value cannot represent #{value.inspect} as #{type} without discarding information"
          end
          return custom_value(casted) unless @codec

          unless @codec.accepts?(casted)
            raise CastingError, "value for #{type} cast to unsupported #{casted.class}"
          end

          PortableValue.typed(casted)
        end

        def serialize(value)
          return if value.nil?

          @codec ? @codec.write(value) : @delegate.serialize(value)
        end

        # Every built-in written form is also a form `cast` accepts losslessly, so the
        # strict door doubles as the trusted one and there is no second parser to keep
        # in step with the writer. A custom type reads its own written form.
        def deserialize(value)
          return if value.nil?

          return custom_value(@delegate.deserialize(value)) unless @codec

          cast(@codec.read(value))
        end

        def type
          @delegate.type
        end

        private
          # A type that supplies its own written form may cast to its own value
          # object. Only the written form has to be portable, so the cast value is
          # frozen and otherwise left alone; deep immutability of a custom value
          # object belongs to the type that defines it.
          def custom_value(value)
            return if value.nil?

            PortableValue.reject_record!(value)
            value.frozen? ? value : value.freeze
          end
      end

      class NestedData < ActiveModel::Type::Value
        attr_reader :data_class

        def initialize(data_class)
          @data_class = data_class
          freeze
        end

        # Nested Ruby class names never cross a boundary: the record's own portable
        # projection already is its written form.
        def serialize(value)
          value&.data
        end

        # Trusted, so a field the local class does not declare is preserved rather
        # than rejected. Without this, adding an optional nested attribute without a
        # version bump would break every worker that has not yet deployed it.
        def deserialize(value)
          return if value.nil?

          unless value.is_a?(Hash)
            raise CastingError, "nested #{data_class} must be reconstructed from a hash"
          end

          data_class.send(:__event_rail_reconstruct__, value)
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
          freeze
        end

        def serialize(value)
          return if value.nil?

          value.map { |item| item_type.serialize(item) }.freeze
        end

        def deserialize(value)
          return if value.nil?

          each_item(value, "reconstructed") { |item| item_type.deserialize(item) }
        end

        def cast(value)
          return if value.nil?

          each_item(value, "constructed") { |item| item_type.cast(item) }
        end

        def type
          :event_rail_array
        end

        private
          def each_item(value, verb)
            unless value.is_a?(Array)
              raise CastingError, "array attribute must be #{verb} from an array"
            end

            value.each_with_index.map do |item, index|
              yield item
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
          Scalar.new(resolve_delegate(cast_type, options))
        end

        array ? ArrayOf.new(type) : type
      rescue ArgumentError => error
        raise DeclarationError, error.message
      end

      def resolve_delegate(cast_type, options)
        delegate = if cast_type.is_a?(ActiveModel::Type::Value)
          cast_type
        else
          if (replacement = REDIRECTED_TYPES[cast_type])
            raise DeclarationError,
              "attribute type #{cast_type.inspect} discards the date portion of an instant; use #{replacement.inspect}"
          end

          ActiveModel::Type.lookup(cast_type, **options)
        end

        verify_portable!(delegate)
        delegate
      end
      private_class_method :resolve_delegate

      # A type is either one EventRail supplies a written form for, or one that
      # supplies its own and proves it here. Proving it at declaration is the point:
      # the alternative is a job that enqueues fine in a unit test and is rejected by
      # the production adapter.
      def verify_portable!(delegate)
        return if SCALAR_CODECS.key?(delegate.type) && !delegate.is_a?(EventRail::PortableType)

        unless delegate.is_a?(EventRail::PortableType)
          raise DeclarationError,
            "attribute type #{delegate.class} reports #{delegate.type.inspect}, which EventRail has no written " \
            "form for; supported types are #{SCALAR_CODECS.keys.sort.join(", ")}, or include " \
            "EventRail::PortableType to supply your own"
        end

        examples = delegate.portable_examples
        unless examples.is_a?(Array) && !examples.empty?
          raise DeclarationError, "#{delegate.class}#portable_examples must return at least one cast value"
        end

        examples.each { |example| verify_example!(delegate, example) }
      end

      def verify_example!(delegate, example)
        written = delegate.serialize(example)
        unless PortableValue.json_primitive?(written)
          raise DeclarationError,
            "#{delegate.class}#serialize returned #{written.class} for #{example.inspect}, which is not a JSON " \
            "primitive, array, or string-keyed hash"
        end

        decoded = JSON.parse(JSON.generate([ written ])).first
        restored = delegate.deserialize(decoded)
        unless restored == example
          raise DeclarationError,
            "#{delegate.class} does not round-trip #{example.inspect}: its written form reconstructs " \
            "#{restored.inspect}"
        end
      rescue DeclarationError
        raise
      rescue StandardError => cause
        raise DeclarationError,
          "#{delegate.class} raised #{cause.class} writing or reading #{example.inspect}: #{cause.message}"
      end
      private_class_method :verify_example!
    end
  end
end
