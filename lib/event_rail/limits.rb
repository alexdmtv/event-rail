module EventRail
  module Limits
    MAX_IDENTIFIER_BYTES = 512
    MAX_SOURCE_BYTES = 255
    MAX_EVENT_TYPE_BYTES = 255
    MAX_EXTENSION_ENTRIES = 32
    MAX_EXTENSION_KEY_BYTES = 64
    MAX_EXTENSION_VALUE_BYTES = 1_024
    MAX_EXTENSIONS_BYTES = 8_192

    # Raw portable structures are application-shaped, so they need a bound that
    # fails during construction rather than as a stack overflow inside a recursive
    # wire reconstruction on a worker.
    MAX_RAW_DEPTH = 32

    # Active Job's argument encoding claims this prefix for its own hash keys, so a
    # payload key using it would either collide with an encoding key or survive as
    # an unintended instruction to the decoder.
    ACTIVE_JOB_RESERVED_KEY_PREFIX = "_aj_".freeze

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
