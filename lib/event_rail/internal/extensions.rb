module EventRail
  module Internal
    # Extensions are durable baggage, so their bounds are the same wherever they are
    # installed: on an event, on a logical context, or merged from both. One
    # implementation keeps the limits from drifting apart between those doors, and the
    # caller supplies the error class so the message names the thing being built.
    module Extensions
      module_function

      EMPTY = {}.freeze

      def validate!(value, error:)
        return EMPTY if value.nil? || (value.is_a?(Hash) && value.empty?)

        unless value.is_a?(Hash)
          raise error, "extensions must be a hash of string keys and values"
        end
        if value.length > Limits::MAX_EXTENSION_ENTRIES
          raise error, "extensions exceed #{Limits::MAX_EXTENSION_ENTRIES} entries"
        end

        total_bytes = 0
        result = value.each_with_object({}) do |(key, item), output|
          unless key.is_a?(String) && item.is_a?(String)
            raise error, "extension keys and values must be strings"
          end
          if Limits::RESERVED_EXTENSION_KEYS.include?(key) || key.start_with?("eventrail.")
            raise error, "extension key #{key.inspect} is reserved"
          end
          if key.empty? || !key.valid_encoding? || key.bytesize > Limits::MAX_EXTENSION_KEY_BYTES
            raise error, "extension key #{key.inspect} is invalid or too long"
          end
          if !item.valid_encoding? || item.bytesize > Limits::MAX_EXTENSION_VALUE_BYTES
            raise error, "extension value for #{key.inspect} is invalid or too long"
          end

          total_bytes += key.bytesize + item.bytesize
          output[key.dup.freeze] = item.dup.freeze
        end

        if total_bytes > Limits::MAX_EXTENSIONS_BYTES
          raise error, "extensions exceed #{Limits::MAX_EXTENSIONS_BYTES} encoded bytes"
        end

        result.freeze
      end

      # Repeating a key with the same value is how a nested scope says "still true".
      # Repeating it with a different value is an attempt to rewrite baggage an
      # ancestor installed, which would make the same key mean different things at
      # different depths of one flow.
      def merge!(inherited, added, error:)
        return inherited if added.nil? || added.empty?

        validated = validate!(added, error: error)
        return validated if inherited.nil? || inherited.empty?

        conflicts = validated.filter_map do |key, value|
          key if inherited.key?(key) && inherited.fetch(key) != value
        end
        unless conflicts.empty?
          raise error, "extension #{conflicts.sort.join(", ")} already has a different value in this context"
        end

        validate!(inherited.merge(validated), error: error)
      end
    end
  end
end
