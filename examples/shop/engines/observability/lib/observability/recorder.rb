module Observability
  # Turns instrumentation into flow records.
  #
  #   publish.event_rail            an event node, whose parent is its causation
  #   enqueue_subscriber.event_rail marks the event a subscriber job is being enqueued for
  #   enqueue(_at).active_job       a job node, whose parent is the message that enqueued it --
  #                                 read from EventRail::Current, which at enqueue time is
  #                                 still the enqueuing code's context
  #   perform.active_job            an attempt, and which job is running while it runs, so a
  #                                 publication inside it can say which job published it
  #   enqueue_retry, retry_stopped, an error the job's own retry_on or discard_on handled: the
  #   discard (.active_job)         attempt still failed, though perform.active_job sees none
  #
  # EventRail's README asks notification handlers neither to raise nor to do slow work. Each
  # handler here does one insert and swallows every error: a recording failure must never
  # fail the flow it records.
  module Recorder
    STACK = :observability_stack

    class << self
      def subscribe
        return if @subscribed

        ActiveSupport::Notifications.subscribe("publish.event_rail") { |event| record { record_event(event.payload) } }
        ActiveSupport::Notifications.subscribe("enqueue_subscriber.event_rail", Scoped.new(:event_id) { |payload| record { record_refused_delivery(payload) } })
        # A job scheduled for later -- the carrier's next step, a retry -- is reported as
        # enqueue_at rather than enqueue.
        ActiveSupport::Notifications.subscribe(/\Aenqueue(_at)?\.active_job\z/) { |event| record { record_job(event.payload) } }
        ActiveSupport::Notifications.subscribe("perform.active_job", Scoped.new(:job) { |payload, frame| record { record_attempt(payload, frame) } })
        ActiveSupport::Notifications.subscribe(/\A(enqueue_retry|retry_stopped|discard)\.active_job\z/) { |event| record { note_handled_error(event.payload) } }
        @subscribed = true
      end

      private
        def record
          yield
        rescue Exception => error # rubocop:disable Lint/RescueException -- recording must never break a flow
          Rails.logger.warn("Observability could not record: #{error.class}: #{error.message}")
        end

        def record_event(payload)
          Node.insert({
            node_id: payload[:event_id], kind: "event", name: payload[:event_type], version: payload[:event_version],
            source: payload[:source], parent_id: payload[:causation_id], correlation_id: payload[:correlation_id],
            published_by_job_id: running_job&.job_id, subscriber_count: payload[:subscriber_count], created_at: Time.current
          }, unique_by: :node_id)
        end

        def record_job(payload)
          job = payload[:job]
          return unless flow_job?(job) && EventRail::Current.correlation_id

          Node.insert({
            node_id: job.job_id, kind: "job", name: job.class.name, parent_id: enqueuing_parent,
            correlation_id: EventRail::Current.correlation_id, outcome: payload[:exception_object] ? "not enqueued" : "enqueued",
            created_at: Time.current
          }, unique_by: :node_id)
        end

        # A subscriber whose own enqueue callback declined, or whose enqueue raised, never
        # becomes a job; it is still part of the flow.
        def record_refused_delivery(payload)
          return if payload[:outcome].to_s == "accepted"

          Node.insert({
            node_id: "#{payload[:event_id]}/#{payload[:job_class]}", kind: "job", name: payload[:job_class].to_s,
            parent_id: payload[:event_id], correlation_id: payload[:correlation_id], outcome: payload[:outcome].to_s,
            created_at: Time.current
          }, unique_by: :node_id)
        end

        def record_attempt(payload, frame)
          job = payload[:job]
          return unless flow_job?(job)

          error = payload[:exception_object] || frame&.fetch(:handled_error, nil)
          Attempt.insert({
            job_id: job.job_id, job_class: job.class.name, number: job.executions, outcome: error ? "failed" : "succeeded",
            error_class: error&.class&.name, error_message: error&.message&.truncate(500),
            duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - frame.fetch(:started_at)) * 1000).round, created_at: Time.current
          })
        end

        def note_handled_error(payload)
          frame = stack.reverse_each.find { |entry| entry[:job].equal?(payload[:job]) }
          frame[:handled_error] = payload[:error] if frame && payload[:error]
        end

        # Only jobs that carry EventRail's context take part in flows. The simulator's tick
        # and the scheduled scans deliberately do not.
        def flow_job?(job) = job.class.include?(EventRail::JobContext)

        def stack = ActiveSupport::IsolatedExecutionState[STACK] || []

        def running_job = stack.reverse_each.find { |entry| entry.key?(:job) }&.fetch(:job)

        # What caused the job being enqueued, judged from the innermost frame only: the event
        # a subscriber is being enqueued for, else the job that is running, else the message
        # of the code that enqueued it -- a checkout request, say. Looking further out would
        # attach a job to an unrelated outer frame when jobs run inline, as in tests.
        def enqueuing_parent
          innermost = stack.last
          if innermost&.key?(:event_id) then innermost[:event_id]
          elsif innermost&.key?(:job) then innermost[:job].job_id
          else EventRail::Current.message_id
          end
        end
    end

    # A listener for a block-form notification that keeps what is running on a per-execution
    # stack between its start and its finish, so that notifications fired inside can see it.
    class Scoped
      def initialize(key, &on_finish)
        @key = key
        @on_finish = on_finish
      end

      def start(_name, _id, payload)
        stack = (ActiveSupport::IsolatedExecutionState[STACK] ||= [])
        stack.push(@key => payload[@key], started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC))
      end

      def finish(_name, _id, payload)
        @on_finish.call(payload, ActiveSupport::IsolatedExecutionState[STACK]&.pop)
      end
    end
  end
end
