require "active_support/current_attributes"
require "securerandom"

module EventRail
  # Execution-scoped lineage, and nothing else.
  #
  # Publication state is deliberately not here: the Rails executor resets current
  # attributes around a job's execution but not around a job performed inside
  # another, so a shared map would behave differently in test than in production.
  # `Internal::Execution` owns that instead.
  #
  # `ActiveSupport::IsolatedExecutionState` defaults to thread isolation, so a host
  # running fiber-per-request must set `config.active_support.isolation_level = :fiber`
  # for lineage to be isolated per request. EventRail documents that requirement
  # rather than claiming an isolation it cannot provide.
  class Current < ActiveSupport::CurrentAttributes
    attribute :message_id, :correlation_id, :causation_id, :originated_at, :extensions

    def extensions
      super || Internal::Extensions::EMPTY
    end
  end

  class << self
    # Establishes logical context for an application-owned ingress boundary: a
    # middleware, a controller hook, a consumer draining a queue, a CLI entry point,
    # a scheduler. EventRail ships no HTTP middleware and harvests nothing from
    # headers, Rails current state, or tracing baggage -- what propagates is what the
    # application installed here.
    #
    # A nested scope inherits lineage and may add extensions. It may not replace an
    # identifier, the origin time, or an extension value with a different one: that
    # would rewrite the lineage of a flow already in progress rather than describe it.
    def with_context(message_id: nil, correlation_id: nil, originated_at: nil, extensions: {})
      inherited = {
        message_id: Current.message_id,
        correlation_id: Current.correlation_id,
        causation_id: Current.causation_id,
        originated_at: Current.originated_at,
        extensions: Current.extensions
      }

      resolved_message_id = resolve_context_identifier(:message_id, message_id, inherited[:message_id]) ||
        SecureRandom.uuid.freeze
      resolved_correlation_id = resolve_context_identifier(:correlation_id, correlation_id, inherited[:correlation_id]) ||
        resolved_message_id
      resolved_originated_at = resolve_context_time(originated_at, inherited[:originated_at])
      resolved_extensions = Internal::Extensions.merge!(
        inherited[:extensions], extensions, error: InvalidContext
      )

      # A block opened inside a running job stays part of that job's execution: its
      # publications keep the job's identity rules and its duplicate record. Only a
      # block with no job around it is a boundary of its own.
      running = Internal::Execution.current
      execution = if running&.derives_identity?
        running
      else
        Internal::Execution.new(scope: resolved_message_id, started_at: resolved_originated_at)
      end

      # A nested scope keeps its parent's causation: the message that caused this flow
      # does not change because the application opened an inner block.
      Internal::Context.establish(
        message_id: resolved_message_id,
        correlation_id: resolved_correlation_id,
        causation_id: inherited[:causation_id],
        originated_at: resolved_originated_at,
        extensions: resolved_extensions
      ) do
        Internal::Execution.wrap(execution) { yield }
      end
    end

    private
      def resolve_context_identifier(name, supplied, inherited)
        return inherited if supplied.nil?

        Metadata.validate_identifier!(supplied, field: name.to_s)
        frozen = supplied.dup.freeze
        if inherited && inherited != frozen
          raise InvalidContext,
            "#{name} is already #{inherited.inspect} in this context and cannot be replaced with #{frozen.inspect}"
        end

        frozen
      rescue InvalidMetadata => error
        raise InvalidContext, error.message
      end

      def resolve_context_time(supplied, inherited)
        return inherited || Internal::Timestamp.normalize(Time.now.utc, field: "originated_at", error: InvalidContext) if supplied.nil?

        normalized = Internal::Timestamp.normalize(supplied, field: "originated_at", error: InvalidContext)
        if inherited && inherited != normalized
          raise InvalidContext,
            "originated_at is already #{inherited.iso8601(6)} in this context and cannot be replaced"
        end

        normalized
      end
  end
end
