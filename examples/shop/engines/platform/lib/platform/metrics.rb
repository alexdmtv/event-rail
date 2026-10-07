require "yabeda"
require "yabeda/activejob"

module Platform
  # Metrics are declared with Yabeda and exported by whichever adapter an environment registers
  # (config.platform.metrics). Each module declares its own, in its engine's lib, which reloading
  # never runs twice; Platform declares those of the whole application. Tags never hold
  # identifiers: each value is a series to store.
  module Metrics
    Yabeda::ActiveJob.install! # jobs: counts, failures, runtime, and latency from enqueue to start

    Yabeda.configure do
      group :platform
      counter :errors_total, tags: %i[ category expected source ], comment: "Errors reported to Rails.error, by category and whether they were an answer"
      counter :staged_jobs_held_total, tags: %i[ job_class ], comment: "Staged jobs left for the relay because the queue could not take them"
      gauge :staged_jobs, comment: "Jobs staged and not yet handed to the queue"
      gauge :oldest_staged_job_age_seconds, unit: :seconds, comment: "How long the oldest staged job has waited: the outbox is stuck when this grows"

      # Read when the monitoring system asks, so a value is never stale.
      collect do
        platform_staged_jobs.set({}, StagedJob.count)
        platform_oldest_staged_job_age_seconds.set({}, StagedJob.minimum(:created_at)&.then { |oldest| (Time.current - oldest).round } || 0)
      end

      group :event_rail
      counter :domain_events_total, tags: %i[ event_type ], comment: "Domain events staged and committed, or published; again when a step is re-run"
    end

    # Each registered adapter, wrapped so a failing monitoring system never fails the request or
    # job it measures. Yabeda's own subscribers are plain notification blocks, whose errors Rails
    # raises into the instrumented code.
    def self.guard_adapters = Yabeda.adapters.transform_values! { |adapter| adapter.is_a?(SafeAdapter) ? adapter : SafeAdapter.new(adapter) }

    class SafeAdapter
      def initialize(adapter) = @adapter = adapter

      %i[ register! perform_counter_increment! perform_gauge_set! perform_gauge_increment! perform_histogram_measure! perform_summary_observe! debug! ].each do |method|
        define_method(method) do |*arguments|
          @adapter.public_send(method, *arguments)
        rescue => error
          Rails.error.report(error, source: "platform.metrics")
          nil
        end
      end
    end

    # A notification subscriber whose own failure is reported, never raised into the code it
    # measures, which Rails would do even inside that code's transaction.
    class Subscriber < ActiveSupport::Subscriber
      def call(event)
        super
      rescue => error
        Rails.error.report(error, source: "platform.metrics")
      end
    end

    # Domain events, counted from EventRail's notifications. A staged one counts once its
    # transaction commits: one rolled back never happened.
    class DomainEvents < Subscriber
      attach_to :event_rail

      def stage(event) = (ActiveRecord.after_all_transactions_commit { count(event) } unless event.payload[:exception])
      def publish(event) = (count(event) unless event.payload[:exception])

      private
        def count(event) = Yabeda.event_rail.domain_events_total.increment(event_type: event.payload[:event_type])
    end

    # Platform's own structured events that are also counted.
    class EventCounts
      NAMES = %w[ platform.error_reported platform.staged_job_held ].freeze

      def emit(event)
        payload = event[:payload]
        case event[:name]
        when "platform.error_reported"
          Yabeda.platform.errors_total.increment(category: payload[:category] || "none", expected: payload[:expected].to_s, source: payload[:source].to_s)
        when "platform.staged_job_held"
          Yabeda.platform.staged_jobs_held_total.increment(job_class: payload[:job_class])
        end
      end
    end
  end
end
