require "active_model/attributes"
require "active_model/validations"

module EventRail
  module Internal
    class AttributeRecord
      # Deliberately not ActiveModel::Model: that bundle also brings Conversion and
      # Access, whose to_model, to_key, to_param, to_partial_path, persisted?, slice
      # and values_at are view and form concerns. They are meaningless on an
      # immutable historical fact and would become public API at 1.0.
      include ActiveModel::Attributes
      include ActiveModel::AttributeAssignment
      include ActiveModel::Validations

      DEFAULT_NOT_GIVEN = Object.new.freeze

      class << self
        def attribute(name, cast_type = nil, default: DEFAULT_NOT_GIVEN, array: false, **options)
          attribute_name = name.to_s
          validate_attribute_name!(attribute_name)

          type = Types.resolve(cast_type, array: array, options: options)

          if default.equal?(DEFAULT_NOT_GIVEN)
            super(attribute_name, type)
          else
            unless PortableValue.literal_default?(default)
              raise DeclarationError, "#{self} attribute #{attribute_name.inspect} cannot use a callable default"
            end

            super(attribute_name, type, default: type.cast(default))
          end
        end

        def reserved_attribute_names
          %w[attributes data errors valid?].freeze
        end

        def record_error_class
          InvalidData
        end

        private
          def validate_attribute_name!(name)
            if reserved_attribute_names.include?(name)
              raise DeclarationError, "#{self} cannot declare reserved attribute #{name.inspect}"
            end

            # Redeclaring an existing attribute is legitimate; its readers are ours.
            return if attribute_types.key?(name)

            shadowed = [ name, "#{name}=" ].find { |candidate| shadows_behavior?(candidate) }
            return unless shadowed

            raise DeclarationError,
              "#{self} cannot declare attribute #{name.inspect} because #{shadowed.inspect} is already defined"
          end

          # A reader can only shadow behavior a caller could have reached, so public
          # and protected methods are the boundary. Ruby defines a large private
          # vocabulary on every object -- format, select, open, p, raise -- and those
          # are ordinary domain words that no reader can shadow, because no caller
          # could have invoked them through the receiver. The record's own private
          # helpers are the exception: those are reached internally, so a reader
          # replacing one would break this class from the inside.
          def shadows_behavior?(name)
            return true if method_defined?(name)
            return false unless private_method_defined?(name)

            owner = instance_method(name).owner
            owner.name.to_s.start_with?("EventRail")
          end

          # Untrusted input: casts, validates, canonicalizes and freezes. State the
          # caller already derived, such as reconstructed metadata, is installed
          # before initialize runs, so no sentinel rides on the public signature.
          #
          # Trusted input arrives in written form and is read back through each
          # declared type's `deserialize` before assignment, which is what lets a
          # nested record preserve fields this version does not declare. Casting then
          # sees values it already accepts, so the strict door stays strict without a
          # second, laxer parser beside it.
          def __event_rail_build__(declared, unknown: {}, state: {}, trusted: false)
            values = trusted ? deserialize_declared(declared) : declared

            record = allocate
            state.each { |ivar, value| record.instance_variable_set(ivar, value) }
            record.instance_variable_set(
              :@unknown_attributes, PortableValue.raw(unknown, path: "unknown attributes")
            )
            record.send(:initialize, values)
            record
          end

          # Partition is by declaration, so a field a newer producer added stays
          # opaque payload without a reader instead of failing the reconstruction.
          def __event_rail_reconstruct__(portable, state: {})
            unless portable.is_a?(Hash) && portable.keys.all? { |key| key.is_a?(String) }
              raise record_error_class, "trusted #{self} data must be a string-keyed hash"
            end

            known_names = attribute_names
            declared, unknown = portable.partition { |name, _value| known_names.include?(name) }.map(&:to_h)
            __event_rail_build__(declared, unknown: unknown, state: state, trusted: true)
          end

          def deserialize_declared(declared)
            types = attribute_types

            declared.each_with_object({}) do |(name, value), result|
              result[name] = begin
                types[name].deserialize(value)
              rescue Error => error
                raise error.class.new("attribute #{name.inspect}: #{error.message}"), cause: error
              end
            end
          end

          # Trusted in-process copy: the source is an instance of this class whose
          # payload is already cast, validated, canonicalized and deeply frozen.
          # Varying state the payload does not depend on cannot invalidate it, so
          # nothing needs recomputing.
          def __event_rail_copy__(source, state: {})
            copy = allocate
            source.instance_variables.each do |ivar|
              copy.instance_variable_set(ivar, source.instance_variable_get(ivar))
            end
            state.each { |ivar, value| copy.instance_variable_set(ivar, value) }
            copy.errors
            copy.freeze
          end
      end

      def initialize(attributes = nil, **keyword_attributes)
        input = normalize_input(attributes, keyword_attributes)
        declared, local_unknown = partition_attributes(input)

        unless local_unknown.empty?
          raise record_error_class, unknown_attributes_message(local_unknown)
        end

        # ActiveModel::Attributes#initialize takes no arguments; assignment is
        # AttributeAssignment's job, which ActiveModel::API used to chain for us.
        super()
        assign_attributes(declared) unless declared.empty?
        self.class.attribute_names.each { |name| public_send(name) }

        @unknown_attributes ||= PortableValue.raw({}, path: "unknown attributes")
        validate_record!
        @data = build_data
        @attributes.freeze
        freeze
      rescue Error
        raise
      rescue ActiveModel::UnknownAttributeError, ArgumentError => error
        raise record_error_class, error.message
      end

      # The written projection of the whole payload: JSON primitives, arrays, and
      # string-keyed hashes, including fields a newer producer added that this version
      # does not declare. This is the single form the private queue representation and
      # the public envelope both read, and it is built once per instance rather than
      # once per serialization.
      def data
        @data
      end

      # Two records of one class that carry the same payload are the same value. The
      # comparison is over the written projection rather than the cast attributes so
      # that a record reconstructed from a queue matches the one it was written from,
      # and so that unknown preserved fields participate.
      def ==(other)
        other.instance_of?(self.class) && other.data == data
      end
      alias_method :eql?, :==

      def hash
        [ self.class, data ].hash
      end

      # An immutable value has no meaningful copy, and Active Model's own
      # initialize_dup deep-dups into an unfrozen attribute set while clearing
      # errors, which would otherwise hand back a mutable record whose readers
      # disagree with its payload view.
      def dup
        frozen? ? self : super
      end

      def clone(freeze: nil)
        frozen? ? self : super
      end

      # Validations already ran once, during construction. Active Model would
      # re-run them here, which raises on a frozen record on Rails 7.2 and can
      # report a published fact as invalid on later versions when a validation
      # depends on external state.
      def valid?(context = nil)
        frozen? ? true : super
      end

      # Object#inspect prints every instance variable, and Active Job logs each
      # argument's inspect by default, so an unmanaged representation publishes
      # domain payload into ordinary application logs.
      def inspect
        "#<#{self.class.name || self.class.inspect}>"
      end

      private
        def attribute_method?(attribute_name)
          self.class.attribute_names.include?(attribute_name)
        end

        def normalize_input(attributes, keyword_attributes)
          unless attributes.nil? || attributes.is_a?(Hash)
            raise record_error_class, "attributes must be supplied as a hash or keywords"
          end

          combined = (attributes || {}).merge(keyword_attributes) do |key|
            raise record_error_class, "attribute #{key.inspect} was supplied more than once"
          end

          combined.each_with_object({}) do |(key, value), result|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise record_error_class, "attribute names must be strings or symbols"
            end

            normalized = key.to_s
            if result.key?(normalized)
              raise record_error_class, "attribute #{normalized.inspect} was supplied more than once"
            end

            result[normalized] = value
          end
        end

        def unknown_attributes_message(unknown)
          "unknown attributes: #{unknown.keys.sort.join(", ")}"
        end

        def partition_attributes(input)
          known_names = self.class.attribute_names
          input.partition { |name, _value| known_names.include?(name) }.map(&:to_h)
        end

        def validate_record!
          return if valid?

          error_hash = errors.to_hash(true).transform_values { |messages| messages.map(&:dup).freeze }.freeze
          raise record_error_class.new(record_validation_message, validation_errors: error_hash)
        end

        # Declared names in declaration order, then preserved unknown fields, so the
        # written form of one logical payload is byte-identical between processes.
        def build_data
          types = self.class.attribute_types
          declared = self.class.attribute_names.to_h do |name|
            [ -name, types[name].serialize(public_send(name)) ]
          end

          declared.merge(@unknown_attributes).freeze
        end

        def record_error_class
          self.class.record_error_class
        end

        def record_validation_message
          "#{self.class} is invalid: #{errors.full_messages.join(", ")}"
        end
    end
  end
end
