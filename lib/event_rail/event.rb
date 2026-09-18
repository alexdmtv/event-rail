module EventRail
  class Event < Internal::AttributeRecord
    VALUE_NOT_GIVEN = Object.new.freeze

    # Metadata an application may supply, but only as an explicit keyword: reaching
    # it through attribute data is how forged lineage would arrive from a params hash.
    KEYWORD_METADATA_NAMES = %w[extensions occurred_at].freeze

    # Metadata an application may never supply. These are derived during publication
    # or arrive through validated reconstruction.
    DERIVED_METADATA_NAMES = %w[causation_id correlation_id id source].freeze

    RESERVED_ATTRIBUTE_NAMES = %w[
      attributes
      contract
      correlation_id
      causation_id
      data
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

        # Only a change is a declaration. Re-running a class body that sets the same value --
        # a `load` rather than a `require`, a reopened class -- alters no contract, so the
        # index is already correct and rejecting it would be a false positive.
        unless @event_type == value
          Internal::Registry.declare_contract(self, caller_locations(1, 1).first)
        end
        @event_type = value.dup.freeze
      end

      def version(value = VALUE_NOT_GIVEN)
        return @event_version if value.equal?(VALUE_NOT_GIVEN)

        unless value.is_a?(Integer) && value.positive?
          raise DeclarationError, "version must be a positive integer"
        end

        unless @event_version == value
          Internal::Registry.declare_contract(self, caller_locations(1, 1).first)
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

      # A class that declares either half of the contract is meant to be published and
      # must declare both. One that declares neither is an application's own abstract
      # base -- `class ApplicationEvent < EventRail::Event` -- and is not a registrable
      # contract, so discovery skips it rather than failing preparation over it.
      def concrete?
        !event_type.nil? || !version.nil?
      end

      def validate_definition!
        unless event_type && version
          raise InvalidContract, "#{self} must explicitly declare event_type and version"
        end

        identity_by.each do |attribute_name|
          unless attribute_names.include?(attribute_name)
            raise InvalidContract, "#{self} identity attribute #{attribute_name.inspect} is not declared"
          end
          unless attribute_types[attribute_name].is_a?(Internal::Types::Scalar)
            raise InvalidContract, "#{self} identity attribute #{attribute_name.inspect} must be scalar"
          end
        end

        true
      end

      def contract_key
        validate_definition!
        [ event_type, version ].freeze
      end

      def reserved_attribute_names
        (super + RESERVED_ATTRIBUTE_NAMES).uniq.freeze
      end

      def record_error_class
        InvalidEvent
      end

      private
        # Not public API: reconstruction of a trusted representation belongs to the
        # private queue serializer and to validated envelope reconstruction, which
        # supply metadata they have already checked. An application that could call
        # this could install any lineage it liked.
        def __reconstruct__(data:, metadata:)
          validate_definition!
          unless metadata.is_a?(Metadata) && metadata.complete?
            raise InvalidMetadata, "trusted reconstruction requires complete metadata"
          end

          __event_rail_reconstruct__(data, state: { :@metadata => metadata })
        end
    end

    attr_reader :metadata

    def initialize(attributes = nil, occurred_at: nil, extensions: {}, **payload)
      self.class.validate_definition!

      # Trusted reconstruction installs complete metadata before initialize runs.
      @metadata ||= Metadata.proposed(occurred_at: occurred_at, extensions: extensions)
      super(attributes, **payload)

      validate_local_identity! unless @metadata.complete?
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

    # Metadata participates, so a proposal and the stamped event copied from it are
    # different values: one is a fact with an identity and the other is a request to
    # record one.
    def ==(other)
      super && other.metadata == metadata
    end
    alias_method :eql?, :==

    def hash
      [ self.class, data, metadata ].hash
    end

    # Contract and metadata only: domain payload and extensions stay out of
    # diagnostics, including Active Job argument logging.
    def inspect
      "#<#{self.class.name || self.class.inspect} type=#{event_type.inspect} version=#{version.inspect} " \
        "id=#{id.inspect} source=#{source.inspect} occurred_at=#{occurred_at.inspect}>"
    end

    private
      # Not public API: stamping installs the identity and lineage that make an event
      # a published fact, and publication is the only thing entitled to do that.
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

        # A metadata-only copy. Reconstructing through the validating constructor
        # would re-cast and re-validate payload this instance already canonicalized,
        # and would rebuild every nested data object, for no change to the payload.
        self.class.send(:__event_rail_copy__, self, state: { :@metadata => stamped_metadata })
      end

      # A declared identity attribute that is nil cannot produce a canonical value, so
      # the event can never be published. The local constructor is the strict door and
      # the only place whose backtrace points at the code that left the field empty.
      # Trusted reconstruction stays permissive: an external event of this contract may
      # legitimately omit a field, and it arrives with an identity already assigned.
      def validate_local_identity!
        missing = self.class.identity_by.select { |name| public_send(name).nil? }
        return if missing.empty?

        raise InvalidEvent,
          "#{self.class} declares #{missing.sort.join(", ")} as logical identity, so it cannot be nil"
      end

      def unknown_attributes_message(unknown)
        names = unknown.keys
        keyword_only = names & KEYWORD_METADATA_NAMES
        derived = names & DERIVED_METADATA_NAMES
        return super if keyword_only.empty? && derived.empty?

        parts = []
        unless keyword_only.empty?
          parts << "#{keyword_only.sort.join(", ")} must be supplied as a keyword argument, not as attribute data"
        end
        unless derived.empty?
          parts << "#{derived.sort.join(", ")} cannot be set locally; event metadata is derived during " \
            "publication or supplied through validated reconstruction"
        end
        remaining = names - keyword_only - derived
        parts << "unknown attributes: #{remaining.sort.join(", ")}" unless remaining.empty?
        parts.join("; ")
      end
  end
end
