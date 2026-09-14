module EventRail
  class Metadata
    attr_reader :id, :source, :occurred_at, :correlation_id, :causation_id, :extensions

    def self.proposed(occurred_at: nil, extensions: {})
      new(occurred_at: occurred_at, extensions: extensions, complete: false)
    end

    def self.complete(id:, source:, occurred_at:, correlation_id:, causation_id: nil, extensions: {})
      new(
        id: id,
        source: source,
        occurred_at: occurred_at,
        correlation_id: correlation_id,
        causation_id: causation_id,
        extensions: extensions,
        complete: true
      )
    end

    def self.validate_source!(value)
      validate_string!(value, field: "source", maximum: Limits::MAX_SOURCE_BYTES)
    end

    def self.validate_identifier!(value, field:, optional: false)
      return if optional && value.nil?

      validate_string!(value, field: field, maximum: Limits::MAX_IDENTIFIER_BYTES)
    end

    def self.validate_string!(value, field:, maximum:)
      unless value.is_a?(String) && !value.empty? && value.valid_encoding?
        raise InvalidMetadata, "#{field} must be a non-empty valid string"
      end
      if value.bytesize > maximum
        raise InvalidMetadata, "#{field} exceeds #{maximum} bytes"
      end

      value
    end
    private_class_method :validate_string!

    def initialize(id: nil, source: nil, occurred_at: nil, correlation_id: nil, causation_id: nil, extensions: {}, complete:)
      if complete
        self.class.validate_identifier!(id, field: "id")
        self.class.validate_source!(source)
        self.class.validate_identifier!(correlation_id, field: "correlation_id")
        self.class.validate_identifier!(causation_id, field: "causation_id", optional: true)
      elsif [ id, source, correlation_id, causation_id ].any?
        raise InvalidMetadata, "local event metadata cannot contain identity, source, correlation, or causation"
      end

      @id = duplicate_and_freeze(id)
      @source = duplicate_and_freeze(source)
      @occurred_at = Internal::Timestamp.cast(occurred_at, field: "occurred_at")
      if complete && @occurred_at.nil?
        raise InvalidMetadata, "occurred_at is required for complete metadata"
      end
      @correlation_id = duplicate_and_freeze(correlation_id)
      @causation_id = duplicate_and_freeze(causation_id)
      @extensions = validate_extensions(extensions)
      @complete = complete
      freeze
    end

    def complete?
      @complete
    end

    # Value equality, so two events carrying the same fact and the same lineage
    # compare equal across a serialization boundary.
    COMPARED_FIELDS = [ :id, :source, :occurred_at, :correlation_id, :causation_id, :extensions ].freeze

    def ==(other)
      other.instance_of?(self.class) &&
        other.complete? == complete? &&
        COMPARED_FIELDS.all? { |field| other.public_send(field) == public_send(field) }
    end
    alias_method :eql?, :==

    def hash
      ([ self.class, @complete ] + COMPARED_FIELDS.map { |field| public_send(field) }).hash
    end

    private
      def duplicate_and_freeze(value)
        value&.dup&.freeze
      end

      def validate_extensions(value)
        unless value.is_a?(Hash)
          raise InvalidMetadata, "extensions must be a hash of string keys and values"
        end
        if value.length > Limits::MAX_EXTENSION_ENTRIES
          raise InvalidMetadata, "extensions exceed #{Limits::MAX_EXTENSION_ENTRIES} entries"
        end

        total_bytes = 0
        result = value.each_with_object({}) do |(key, item), output|
          unless key.is_a?(String) && item.is_a?(String)
            raise InvalidMetadata, "extension keys and values must be strings"
          end
          if Limits::RESERVED_EXTENSION_KEYS.include?(key) || key.start_with?("eventrail.")
            raise InvalidMetadata, "extension key #{key.inspect} is reserved"
          end
          if key.empty? || !key.valid_encoding? || key.bytesize > Limits::MAX_EXTENSION_KEY_BYTES
            raise InvalidMetadata, "extension key #{key.inspect} is invalid or too long"
          end
          if !item.valid_encoding? || item.bytesize > Limits::MAX_EXTENSION_VALUE_BYTES
            raise InvalidMetadata, "extension value for #{key.inspect} is invalid or too long"
          end

          total_bytes += key.bytesize + item.bytesize
          output[key.dup.freeze] = item.dup.freeze
        end

        if total_bytes > Limits::MAX_EXTENSIONS_BYTES
          raise InvalidMetadata, "extensions exceed #{Limits::MAX_EXTENSIONS_BYTES} encoded bytes"
        end

        result.freeze
      end
  end
end
