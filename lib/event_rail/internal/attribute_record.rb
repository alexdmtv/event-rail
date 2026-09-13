require "active_model/attributes"
require "active_model/validations"

module EventRail
  module Internal
    class AttributeRecord
      include ActiveModel::Model
      include ActiveModel::Attributes

      DEFAULT_NOT_GIVEN = Object.new.freeze
      INTERNAL_TOKEN = Object.new.freeze

      class << self
        def attribute(name, cast_type = nil, default: DEFAULT_NOT_GIVEN, array: false, **options)
          attribute_name = name.to_s
          validate_attribute_name!(attribute_name)

          type, definition = Types.resolve(cast_type, array: array, options: options)
          own_attribute_definitions[attribute_name] = definition

          if default.equal?(DEFAULT_NOT_GIVEN)
            super(attribute_name, type)
          else
            unless PortableValue.literal_default?(default)
              raise DeclarationError, "#{self} attribute #{attribute_name.inspect} cannot use a callable default"
            end

            super(attribute_name, type, default: type.cast(default))
          end
        end

        def event_rail_attribute_definitions
          inherited = if superclass.respond_to?(:event_rail_attribute_definitions)
            superclass.event_rail_attribute_definitions
          else
            {}
          end

          inherited.merge(own_attribute_definitions).freeze
        end

        def reserved_attribute_names
          %w[attributes errors valid?].freeze
        end

        private
        def own_attribute_definitions
          @event_rail_attribute_definitions ||= {}
        end

        def validate_attribute_name!(name)
          return unless reserved_attribute_names.include?(name)

          raise DeclarationError, "#{self} cannot declare reserved attribute #{name.inspect}"
        end

        def internal_unknown(unknown)
          [ INTERNAL_TOKEN, unknown ]
        end
      end

      def initialize(attributes = nil, __event_rail_internal__: nil, **keyword_attributes)
        input = normalize_input(attributes, keyword_attributes)
        unknown = extract_internal_unknown(__event_rail_internal__)
        declared, local_unknown = partition_attributes(input)

        unless local_unknown.empty?
          raise record_error_class, "unknown attributes: #{local_unknown.keys.sort.join(", ")}"
        end

        super(declared)
        self.class.attribute_names.each { |name| public_send(name) }

        @unknown_attributes = PortableValue.raw(unknown, path: "unknown attributes")
        validate_record!
        @canonical_attributes = build_canonical_attributes
        @attributes.freeze
        freeze
      rescue Error
        raise
      rescue ActiveModel::UnknownAttributeError, ArgumentError => error
        raise record_error_class, error.message
      end

      def attributes
        return @canonical_attributes if defined?(@canonical_attributes)

        super
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

      def extract_internal_unknown(internal)
        return {} if internal.nil?

        token, unknown = internal
        unless token.equal?(INTERNAL_TOKEN) && unknown.is_a?(Hash)
          raise record_error_class, "invalid internal reconstruction state"
        end

        unknown
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

      def build_canonical_attributes
        declared = self.class.attribute_names.to_h do |name|
          [ name.dup.freeze, PortableValue.export(public_send(name), path: name) ]
        end

        declared.merge(@unknown_attributes).freeze
      end

      def record_error_class
        InvalidData
      end

      def record_validation_message
        "#{self.class} is invalid: #{errors.full_messages.join(", ")}"
      end
    end
  end
end
