require "minitest/autorun"
require "active_job"
require "event_rail"
require "sidekiq"
require "sidekiq/test_api"
require "shoryuken"

module AdapterConformanceFixtures
  class << self
    attr_accessor :enqueued_classes
  end

  self.enqueued_classes = []

  class SidekiqJob < ActiveJob::Base
    self.queue_adapter = :sidekiq

    before_enqueue { AdapterConformanceFixtures.enqueued_classes << self.class.name }

    def perform(value)
      value
    end
  end

  class ShoryukenJob < ActiveJob::Base
    self.queue_adapter = :shoryuken

    before_enqueue { AdapterConformanceFixtures.enqueued_classes << self.class.name }

    def perform(value)
      value
    end
  end
end
class AdapterConformanceTest < Minitest::Test
  Response = Data.define(:message_id)

  class FakeQueue
    attr_reader :messages

    def initialize
      @messages = []
    end

    def fifo?
      false
    end

    def send_message(attributes)
      messages << attributes
      Response.new("sqs-message-id")
    end
  end

  def setup
    AdapterConformanceFixtures.enqueued_classes.clear
  end

  def test_sidekiq_individual_enqueue_uses_the_public_active_job_path
    Sidekiq::Testing.fake! do
      Sidekiq::Queues.clear_all
      job = AdapterConformanceFixtures::SidekiqJob.perform_later("value")

      assert_predicate job, :successfully_enqueued?
      assert job.provider_job_id
      assert_equal [ "AdapterConformanceFixtures::SidekiqJob" ], AdapterConformanceFixtures.enqueued_classes
      assert_equal 1, Sidekiq::Queues["default"].size
    end
  end

  def test_shoryuken_individual_enqueue_uses_the_public_active_job_path
    queue = FakeQueue.new
    original_queues = Shoryuken::Client.method(:queues)
    Shoryuken::Client.define_singleton_method(:queues) { |_name| queue }

    job = AdapterConformanceFixtures::ShoryukenJob.perform_later("value")

    assert_predicate job, :successfully_enqueued?
    assert_equal [ "AdapterConformanceFixtures::ShoryukenJob" ], AdapterConformanceFixtures.enqueued_classes
    assert_equal 1, queue.messages.length
  ensure
    Shoryuken::Client.define_singleton_method(:queues, original_queues) if original_queues
  end
end
