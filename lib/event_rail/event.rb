module EventRail
  class Event < Internal::AttributeRecord
    VALUE_NOT_GIVEN = Object.new.freeze
    INTERNAL_TOKEN = Object.new.freeze

    RESERVED_ATTRIBUTE_NAMES = %w[
      attributes
      contract
      correlation_id
      causation_id
      default_source
      errors
      event_type
      extensions
      id
      identity_by
      metadata
      occurred_at
      payload
      source
      stamped?
      type
      valid?
      version
    ].freeze

    class << self
      def event_type(value = VALUE_NOT_GIVEN)
        return @event_type if value.equal?(VALUE_NOT_GIVEN)

        unless value.is_a?(String) && !value.empty? && value.valid_encoding?
          raise DeclarationError, "event_type must be a non-empty valid string"
        end
        if value.bytesize > Limits::MAX_EVENT_TYPE_BYTES
          raise DeclarationError, "event_type exceeds #{Limits::MAX_EVENT_TYPE_BYTES} bytes"
        end

        @event_type = value.dup.freeze
      end

      def version(value = VALUE_NOT_GIVEN)
        return @event_version if value.equal?(VALUE_NOT_GIVEN)

        unless value.is_a?(Integer) && value.positive?
          raise DeclarationError, "version must be a positive integer"
        end

        @event_version = value
      end

      def default_source(value = VALUE_NOT_GIVEN)
        if value.equal?(VALUE_NOT_GIVEN)
          return @default_source if instance_variable_defined?(:@default_source)
          return superclass.default_source if superclass.respond_to?(:default_source)

          return
        end

        Metadata.validate_source!(value)
        @default_source = value.dup.freeze
      rescue InvalidMetadata => error
        raise DeclarationError, error.message
      end

      def identity_by(*attribute_names)
        return (@identity_attributes || []).dup.freeze if attribute_names.empty?

        names = attribute_names.map(&:to_s)
        if names.empty? || names.any?(&:empty?) || names.uniq.length != names.length
          raise DeclarationError, "identity_by requires unique non-empty attribute names"
        end

        @identity_attributes = names.map(&:freeze).freeze
      end

      def validate_definition!
        unless event_type && version
          raise InvalidContract, "#{self} must explicitly declare event_type and version"
        end

        identity_by.each do |attribute_name|
          definition = event_rail_attribute_definitions[attribute_name]
          unless definition
            raise InvalidContract, "#{self} identity attribute #{attribute_name.inspect} is not declared"
          end
          if definition.array || %i[raw data].include?(definition.kind)
            raise InvalidContract, "#{self} identity attribute #{attribute_name.inspect} must be scalar"
          end
        end

        true
      end

      def contract_key
        validate_definition!
        [ event_type, version ].freeze
      end

      def __reconstruct__(data:, metadata:)
        validate_definition!
        unless data.is_a?(Hash) && data.keys.all? { |key| key.is_a?(String) }
          raise InvalidEvent, "trusted event data must be a string-keyed hash"
        end
        unless metadata.is_a?(Metadata) && metadata.complete?
          raise InvalidMetadata, "trusted reconstruction requires complete metadata"
        end

        known_names = attribute_names
        declared, unknown = data.partition { |name, _value| known_names.include?(name) }.map(&:to_h)
        new(
          declared,
          __event_rail_internal__: [ INTERNAL_TOKEN, metadata, unknown ]
        )
      end

      def reserved_attribute_names
        (super + RESERVED_ATTRIBUTE_NAMES).uniq.freeze
      end
    end

    attr_reader :metadata

    def initialize(attributes = nil, occurred_at: nil, extensions: {}, __event_rail_internal__: nil, **payload)
      self.class.validate_definition!

      if __event_rail_internal__
        token, trusted_metadata, unknown = __event_rail_internal__
        unless token.equal?(INTERNAL_TOKEN)
          raise InvalidEvent, "invalid trusted event reconstruction"
        end

        @metadata = trusted_metadata
        internal_unknown = Internal::AttributeRecord.send(:internal_unknown, unknown)
        super(attributes, __event_rail_internal__: internal_unknown, **payload)
      else
        @metadata = Metadata.proposed(occurred_at: occurred_at, extensions: extensions)
        super(attributes, **payload)
      end
    end

    def event_type
      self.class.event_type
    end

    def version
      self.class.version
    end

    def id
      metadata.id
    end

    def source
      metadata.source
    end

    def occurred_at
      metadata.occurred_at
    end

    def correlation_id
      metadata.correlation_id
    end

    def causation_id
      metadata.causation_id
    end

    def extensions
      metadata.extensions
    end

    def stamped?
      metadata.complete?
    end

    def __stamp__(id:, source: nil, occurred_at: nil, correlation_id:, causation_id: nil, extensions: nil)
      resolved_source = source || self.class.default_source
      raise InvalidMetadata, "source is required to stamp #{self.class}" unless resolved_source

      stamped_metadata = Metadata.complete(
        id: id,
        source: resolved_source,
        occurred_at: occurred_at || metadata.occurred_at,
        correlation_id: correlation_id,
        causation_id: causation_id,
        extensions: extensions || metadata.extensions
      )

      self.class.__reconstruct__(data: attributes, metadata: stamped_metadata)
    end

    private
      def record_error_class
        InvalidEvent
      end

      def record_validation_message
        "#{self.class} is invalid: #{errors.full_messages.join(", ")}"
      end
  end
end
