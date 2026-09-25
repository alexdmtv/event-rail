require "test_helper"
require "event_rail/test_helper"

# Observability depends on no business module, so its tests bring their own events and
# subscribers, declared through EventRail's test door. Declared subscribers stay dormant until
# a test activates them with with_subscribers.
EventRail::TestHelper.declare do
  module Observability
    module Probe
      class Happened < EventRail::Event
        event_type "observability_probe.happened"
        version 1
        default_source "shop.probe"
        identity_by :ref

        attribute :ref, :string
      end

      class FollowedUp < EventRail::Event
        event_type "observability_probe.followed_up"
        version 1
        default_source "shop.probe"
        identity_by :ref

        attribute :ref, :string
      end

      class FirstJob < Platform::ApplicationJob
        subscribes_to Happened

        def perform(event) = EventRail.publish(FollowedUp.new(ref: event.ref))
      end

      class SecondJob < Platform::ApplicationJob
        subscribes_to Happened

        def perform(event) = nil
      end
    end
  end
end

module Observability
  class RecorderTest < ActiveSupport::TestCase
    include EventRail::TestHelper

    def publish_in_a_flow
      EventRail.with_context(message_id: "probe-request") do
        EventRail.publish(Probe::Happened.new(ref: "r-1")).event
      end
    end

    test "a publication with two subscribers is recorded once, with its two deliveries" do
      with_subscribers(Probe::FirstJob, Probe::SecondJob) do
        event = publish_in_a_flow

        assert_equal 1, Node.events.where(node_id: event.id).count
        assert_equal %w[ Observability::Probe::FirstJob Observability::Probe::SecondJob ],
          Node.jobs.where(parent_id: event.id).pluck(:name).sort
      end
    end

    test "an event published inside a subscriber is attributed to it" do
      with_subscribers(Probe::FirstJob) do
        event = publish_in_a_flow
        perform_enqueued_jobs

        subscriber_job = Node.jobs.find_by!(parent_id: event.id)
        follow_up = Node.events.find_by!(name: "observability_probe.followed_up")
        assert_equal subscriber_job.node_id, follow_up.published_by_job_id
        assert_equal "succeeded", Attempt.find_by!(job_id: subscriber_job.node_id).outcome
      end
    end

    test "a failed attempt is recorded with its error" do
      with_subscribers(Probe::FirstJob) do
        publish_in_a_flow
        Probe::FirstJob.define_method(:perform) { |_event| raise "boom" }

        assert_raises(RuntimeError) { perform_enqueued_jobs }

        attempt = Attempt.find_by!(job_class: "Observability::Probe::FirstJob")
        assert_equal [ "failed", "RuntimeError", "boom" ], [ attempt.outcome, attempt.error_class, attempt.error_message ]
      ensure
        Probe::FirstJob.define_method(:perform) { |event| EventRail.publish(Probe::FollowedUp.new(ref: event.ref)) }
      end
    end

    test "a publication succeeds and its subscribers are enqueued when recording fails" do
      Node.define_singleton_method(:insert) { |*, **| raise ActiveRecord::StatementInvalid, "database is locked" }

      with_subscribers(Probe::FirstJob) do
        publication = EventRail.with_context(message_id: "probe-request") { EventRail.publish(Probe::Happened.new(ref: "r-1")) }

        assert_equal [ Probe::FirstJob ], publication.accepted_subscribers
        assert_enqueued_jobs 1
      end
    ensure
      Node.singleton_class.remove_method(:insert)
    end

    test "a job that carries no EventRail context is not part of any flow" do
      perform_enqueued_jobs { PruneJob.perform_later }

      assert_equal 0, Node.jobs.count
      assert_equal 0, Attempt.count
    end
  end

  class PruneJobTest < ActiveSupport::TestCase
    test "keeps only the newest records" do
      5.times { |index| Node.create!(node_id: "n-#{index}", kind: "event", name: "x.y", created_at: Time.current) }

      PruneJob.perform_now(keep: 2)

      assert_equal %w[ n-3 n-4 ], Node.order(:id).pluck(:node_id)
    end
  end
end
