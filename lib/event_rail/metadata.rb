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
        Internal::Extensions.validate!(value, error: InvalidMetadata)
      end
  end
end
