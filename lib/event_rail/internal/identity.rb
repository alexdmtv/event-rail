require "active_support/core_ext/digest/uuid"
require "bigdecimal"
require "date"

module EventRail
  module Internal
    # Retry-stable publication identity.
    #
    # The whole point is that the same logical fact, published again by the same
    # execution, derives the same event ID -- so a consumer can collapse the
    # duplicates at-least-once delivery guarantees it will see. That makes both the
    # namespace and the encoding permanent compatibility state: changing either
    # silently gives every future publication a different ID for an unchanged fact,
    # which is why the golden vectors are asserted rather than merely computed.
    module Identity
      module_function

      # Derived from the URL namespace rather than written as a literal, so the input
      # that produced it stays visible and a typo cannot masquerade as a deliberate
      # value. The golden-vector test pins the result.
      NAMESPACE = Digest::UUID.uuid_v5(
        Digest::UUID::URL_NAMESPACE, "https://github.com/event_rail/event_rail/identity/v1"
      ).freeze

      # The first publication of an event type in one execution needs no key: there is
      # nothing to distinguish it from.
      SINGLETON = :__event_rail_singleton__

      def derive(source:, job_class:, scope:, event_type:, version:, logical_identity:)
        Digest::UUID.uuid_v5(
          NAMESPACE,
          encode([ source, job_class, scope, event_type, version, logical_identity ])
        )
      end

      # Length-delimited and type-tagged. Ruby's own Hash#hash is per-process, inspect
      # is not a format, and a plain join makes ["ab", "c"] and ["a", "bc"] the same
      # string. A tag also keeps 1 and "1" apart, so a call site that passes an integer
      # key cannot collide with one that passes its decimal spelling.
      def encode(components)
        components.map { |component| encode_component(component) }.join
      end

      def encode_component(value)
        tag, bytes = case value
        when SINGLETON then [ "*", "" ]
        when String then [ "s", value.b ]
        when true then [ "b", "true" ]
        when false then [ "b", "false" ]
        when Integer then [ "i", value.to_s ]
        when BigDecimal
          reject!(value, "a finite number") unless value.finite?
          [ "d", value.to_s("F") ]
        when Float
          reject!(value, "a finite number") unless value.finite?
          [ "f", format("%.17g", value) ]
        when Time then [ "T", Timestamp.written(value) ]
        when DateTime
          reject!(value, "a Time rather than a DateTime")
        when Date then [ "D", value.iso8601 ]
        when Array
          [ "L", "#{value.length}:#{encode(value.map { |item| encode_scalar!(item) })}" ]
        else
          reject!(value, "a non-null scalar")
        end

        "#{tag}#{bytes.bytesize}:#{bytes}"
      end

      # An identity component that is a structure cannot be canonicalized without
      # choosing an ordering and a separator that would then be permanent, and one
      # that is null cannot identify anything.
      def encode_scalar!(value)
        case value
        when String, Integer, Float, BigDecimal, Time, true, false then value
        when DateTime then reject!(value, "a Time rather than a DateTime")
        when Date then value
        else reject!(value, "a non-null scalar")
        end
      end
      private_class_method :encode_scalar!

      def reject!(value, expectation)
        raise PublicationError,
          "cannot derive publication identity from #{value.inspect}; every component must be #{expectation}"
      end
      private_class_method :reject!
    end
  end
end
