module EventRail
  module Limits
    MAX_IDENTIFIER_BYTES = 512
    MAX_SOURCE_BYTES = 255
    MAX_EVENT_TYPE_BYTES = 255
    MAX_EXTENSION_ENTRIES = 32
    MAX_EXTENSION_KEY_BYTES = 64
    MAX_EXTENSION_VALUE_BYTES = 1_024
    MAX_EXTENSIONS_BYTES = 8_192

    RESERVED_EXTENSION_KEYS = %w[
      id
      source
      occurred_at
      correlation_id
      causation_id
      traceparent
      tracestate
    ].freeze
  end
end
