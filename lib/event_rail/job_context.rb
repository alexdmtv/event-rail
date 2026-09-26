require "active_support/concern"
require "securerandom"

module EventRail
  # Opt a regular Active Job base class into logical context propagation:
  #
  #   class ApplicationJob < ActiveJob::Base
  #     include EventRail::JobContext
  #   end
  #
  # EventRail ships no initializer, install generator, or global prepend. Prepending
  # every `ActiveJob::Base` would change serialization for jobs whose owners never
  # asked, and editing `ApplicationJob` from a generator assumes there is exactly one
  # and that it is unmodified. The explicit inclusion keeps ownership visible, and
  # application preparation fails with a precise message when a declared subscriber
  # is missing it.
  module JobContext
    extend ActiveSupport::Concern

    # One reserved key in the job's serialized data, carrying only JSON primitives.
    ENTRY_KEY = "event_rail_context".freeze
    ENTRY_VERSION = 1
    SUPPORTED_ENTRY_VERSIONS = [ ENTRY_VERSION ].freeze

    included do
      around_perform do |job, block|
        job.send(:__event_rail_around_perform__, &block)
      end
    end

    # The entry is established exactly once per job instance and then re-emitted
    # unchanged. Reading ambient context here instead would lose lineage on the path
    # this design depends on most: when `retry_on` retries, Active Job serializes
    # *after* the surrounding perform callbacks have already restored the previous
    # context, so an ambient read would generate a fresh root on every retry. The
    # instance survives, because `retry_job` re-enqueues the same object.
    def serialize
      super.merge(ENTRY_KEY => __event_rail_entry__)
    end

    def deserialize(job_data)
      super
      @__event_rail_entry__ = __event_rail_read_entry__(job_data[ENTRY_KEY])
    end

    private
      # A subscriber's logical message is the event it is handling rather than the job
      # that delivers it, so the subscriber integration overrides this. A regular job
      # has no delivered event and speaks for itself.
      def __event_rail_delivered_event__
        nil
      end

      def __event_rail_entry__
        @__event_rail_entry__ ||= __event_rail_build_entry__
      end

      # A job queued before context integration was deployed has no entry, and must
      # still run: it becomes the root of its own causal chain rather than failing
      # deserialization.
      def __event_rail_build_entry__
        message_id = job_id || SecureRandom.uuid
        originated_at = Current.originated_at || Time.now.utc

        {
          "v" => ENTRY_VERSION,
          "message_id" => message_id,
          "correlation_id" => Current.correlation_id || message_id,
          "causation_id" => Current.message_id,
          "originated_at" => Internal::Timestamp.written(originated_at),
          "extensions" => Current.extensions
        }
      end

      def __event_rail_read_entry__(raw)
        return nil unless raw.is_a?(Hash)

        version = raw["v"]
        unless SUPPORTED_ENTRY_VERSIONS.include?(version)
          raise UnsupportedFormatError.new(
            format_version: version, supported_format_versions: SUPPORTED_ENTRY_VERSIONS
          )
        end

        # The adapter owns the hash it handed us, and the entry is mutated during
        # execution to record when the attempt started.
        raw.dup
      end

      def __event_rail_around_perform__(&block)
        entry = __event_rail_entry__
        event = __event_rail_delivered_event__

        # Recorded on the entry at the first attempt and re-emitted by every later
        # serialization, which is what makes a default occurrence time stable across
        # this job's Active Job retries rather than tracking the retry's own start.
        entry["execution_started_at"] ||= Internal::Timestamp.written(Time.now.utc)
        started_at = Internal::Timestamp.normalize(
          entry["execution_started_at"], field: "execution_started_at"
        )

        message_id = event ? event.id : entry["message_id"]
        correlation_id = event ? event.correlation_id : entry["correlation_id"]
        causation_id = event ? event.causation_id : entry["causation_id"]
        extensions = event ? event.extensions : Internal::Extensions.validate!(
          entry["extensions"], error: InvalidContext
        )

        # The scope an undeclared follow-up's ID derives from. A subscriber's is the event
        # it handles, by source as well as ID, since two producers may use one ID; its
        # logical message and causation stay the event's ID.
        execution = Internal::Execution.new(
          job_class: self.class.name, scope: event ? [ event.source, event.id ] : message_id, started_at: started_at
        )

        Internal::Context.establish(
          message_id: message_id,
          correlation_id: correlation_id,
          causation_id: causation_id,
          originated_at: Internal::Timestamp.normalize(entry["originated_at"], field: "originated_at"),
          extensions: extensions
        ) do
          Internal::Execution.wrap(execution) { block.call }
        end
      end
  end
end
