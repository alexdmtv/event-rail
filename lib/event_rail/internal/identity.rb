require "active_support/core_ext/digest/uuid"
require "active_support/core_ext/object/blank"
require "bigdecimal"
require "date"

module EventRail
  module Internal
    # Publication identity: the ID an event derives, so that the same fact published
    # again derives the same ID and a consumer can collapse the duplicates at-least-once
    # delivery guarantees it will see.
    #
    # Two derivations, told apart by a leading tag so their inputs never coincide:
    #
    #   fact       ["fact", source, event_type, identity_list]
    #              for an event with declared identity. Nothing about who published it,
    #              when, or in which schema version: one fact, one ID, everywhere.
    #   execution  ["execution", source, job_class, scope, event_type, version, SINGLETON]
    #              for an event without declared identity, published inside a job. Stable
    #              across that job's retries and across redeliveries of the event a
    #              subscriber handles, and nothing more.
    #
    # The namespace, the tags, the component order and the byte encoding are permanent
    # compatibility state, documented in the README with vectors other implementations
    # can reproduce; changing any of them silently gives every future publication a
    # different ID for an unchanged fact, which is why the vectors are asserted rather
    # than merely computed.
    module Identity
      module_function

      # A literal, owned by this project and named nowhere else, so no one else's
      # derivation can land in the same space.
      NAMESPACE = "21fedac0-42c6-443f-b01c-6980aab52f32".freeze

      # Closes the execution rule's name: an undeclared event is identified by the
      # execution and its type alone, which is why one execution publishes it once.
      SINGLETON = :__event_rail_singleton__

      # `identity` is always a list: the declared attributes' values in declaration
      # order, or one explicit publication identity. So an explicit "a" and a single
      # declared attribute whose value is "a" name the same fact.
      def fact(source:, event_type:, identity:)
        raise ArgumentError, "fact identity must be a list; got #{identity.inspect}" unless identity.is_a?(Array)

        uuid_v5(encode([ "fact", source, event_type, identity ]))
      end

      def execution(source:, job_class:, scope:, event_type:, version:)
        uuid_v5(encode([ "execution", source, job_class, scope, event_type, version, SINGLETON ]))
      end

      def uuid_v5(name) = Digest::UUID.uuid_v5(NAMESPACE, name)
      private_class_method :uuid_v5

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
        when String then [ "s", utf8_bytes(value) ]
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

      # A string is hashed as its UTF-8 bytes, with no Unicode normalization: the same
      # text in another normal form is another identity, so a producer must send the same
      # bytes. Bytes that are not valid UTF-8 have no portable spelling at all.
      def utf8_bytes(value)
        utf8 = value.encoding == Encoding::UTF_8 ? value : value.encode(Encoding::UTF_8)
        reject!(value, "valid UTF-8") unless utf8.valid_encoding?
        utf8.b
      rescue EncodingError
        reject!(value, "valid UTF-8")
      end
      private_class_method :utf8_bytes

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
