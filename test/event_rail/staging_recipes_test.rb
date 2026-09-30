require "test_helper"
require "active_record"

# The README's two stagers, exercised against real transactions. Each recipe here is the
# README's code adapted to this file's tables: `StagingRecipes::RecipeRecord` stands in for the
# README's `ApplicationRecord`, and the outbox names its table. A change to a recipe must be
# made in both places.
#
# Their own connections, rather than ActiveRecord::Base's: another fixture re-establishes
# that one, which would drop these tables mid-run. In-memory SQLite keeps them serviceless.
# Everything lives under StagingRecipes, so no top-level constant leaks into the suite.
module StagingRecipes
  class RecipeRecord < ActiveRecord::Base
    self.abstract_class = true
    establish_connection(adapter: "sqlite3", database: ":memory:")
  end

  # A second database, for a transaction the outbox's own connection cannot see.
  class OtherRecord < ActiveRecord::Base
    self.abstract_class = true
    establish_connection(adapter: "sqlite3", database: ":memory:")
  end

  RecipeRecord.connection.create_table(:staged_jobs) do |t|
    t.string :job_id, null: false, index: { unique: true }
    t.json :payload, null: false
    t.datetime :created_at, null: false
  end
  RecipeRecord.connection.create_table(:recipe_orders) { |t| t.string :state }
  RecipeRecord.connection.create_table(:queue_rows) { |t| t.string :job_id, null: false }
  OtherRecord.connection.create_table(:other_rows) { |t| t.string :name }

  class RecipeOrder < RecipeRecord
    self.table_name = "recipe_orders"
  end

  class OtherRow < OtherRecord
    self.table_name = "other_rows"
  end

  # --- Recipe 1: an outbox table in the application's database --------------------

  class StagedJob < RecipeRecord
    self.table_name = "staged_jobs"

    # One insert_all! statement writes every row or none. Not insert_all, which skips a
    # conflicting row without saying so.
    def self.stage(jobs)
      raise ArgumentError, "#{name}.stage needs an open transaction to commit with" unless current_transaction.open?
      return if jobs.empty?

      now = Time.current
      insert_all!(jobs.map { |job| { job_id: job.job_id, payload: job.serialize, created_at: now } })

      # After every open transaction commits, so the enqueue is immediate whatever the
      # deferral setting, and a row is never deleted for an enqueue that was only deferred.
      ActiveRecord.after_all_transactions_commit { jobs.each { |job| hand_over(job) } }
    end

    # Deletes the row once the queue took the job, or once a subscriber's own enqueue callback
    # declined it; anything else leaves it for the relay.
    def self.hand_over(job)
      job.enqueue
      if job.enqueue_error
        Rails.logger.warn("Staged job #{job.job_id} left for the relay: #{job.enqueue_error.message}")
      else
        Rails.logger.warn("Staged job #{job.job_id} declined by its enqueue callback") unless job.successfully_enqueued?
        where(job_id: job.job_id).delete_all
      end
    rescue => error
      Rails.logger.warn("Staged job #{job.job_id} left for the relay: #{error.class}: #{error.message}")
    end

    # Run on a schedule, every second or so. A row that cannot even be loaded -- its job class
    # renamed while it waited -- is left and logged, and the rows after it are still handed over.
    def self.relay(older_than: 5.seconds)
      where(created_at: ...older_than.ago).find_each do |row|
        hand_over(ActiveJob::Base.deserialize(row.payload))
      rescue => error
        Rails.logger.warn("Staged job #{row.job_id} left for the relay: #{error.class}: #{error.message}")
      end
    end
  end

  # --- Recipe 2: a queue that lives in the application's database -----------------

  module QueueStager
    module_function

    def stage(jobs)
      raise ArgumentError, "QueueStager.stage needs an open transaction" unless queue_record.current_transaction.open?

      deferred = jobs.map(&:class).uniq.select { |job_class| deferred?(job_class) }
      raise ArgumentError, "#{deferred.map(&:name).join(", ")} defer enqueuing until after commit" if deferred.any?

      # A savepoint, so a later job's failure takes the earlier ones with it even if the
      # caller rescues the error and commits.
      queue_record.transaction(requires_new: true) do
        jobs.each do |job|
          job.enqueue
          raise job.enqueue_error if job.enqueue_error
        end
      end
    end

    # Whether Active Job would defer this class's enqueue to after the commit. The setting's
    # meaning moved between versions, and it is interpreted when a job is enqueued, not when
    # it is set.
    def deferred?(job_class)
      setting = job_class.enqueue_after_transaction_commit

      if ActiveJob.version < Gem::Version.new("8.0")
        # 7.2: the adapter decides unless the class said :never or :always.
        case setting
        when :never then false
        when :always then true
        else job_class.queue_adapter.enqueue_after_transaction_commit?
        end
      elsif ActiveJob.version < Gem::Version.new("8.1")
        # 8.0: the old symbols still mean what they meant, with a deprecation warning.
        case setting
        when :never, :default then false
        when :always then true
        else setting ? true : false
        end
      else
        # 8.1 on: any truthy value defers, the old symbols included.
        setting ? true : false
      end
    end

    # The README's ApplicationRecord.
    def queue_record
      RecipeRecord
    end
  end
end

Registry.reopen do
  module RecipeFixtures
    class Shipped < EventRail::Event
      event_type "tests.recipe_shipped"
      version 1
      default_source "acme.orders"

      attribute :order_id, :string
      identity_by :order_id
    end

    class Base < ActiveJob::Base
      include EventRail::JobContext
    end

    class Notify < Base
      subscribes_to Shipped

      def perform(event)
        event
      end
    end

    class Invoice < Base
      subscribes_to Shipped

      def perform(event)
        event
      end
    end

    class Runner < Base
      cattr_accessor :body

      def perform
        body.call
      end
    end
  end
end

Registry.prepare

module StagingRecipes
  class RecipesTest < ActiveSupport::TestCase
    # A queue adapter writing its rows through the application's connection, as a database
    # queue does. It can be told to fail on a given push.
    class DatabaseQueue < ActiveJob::QueueAdapters::AbstractAdapter
      attr_accessor :fail_on

      def enqueue(job)
        @pushes = (@pushes || 0) + 1
        raise ActiveRecord::StatementInvalid, "queue full" if fail_on == @pushes

        RecipeRecord.connection.insert("INSERT INTO queue_rows (job_id) VALUES (#{RecipeRecord.connection.quote(job.job_id)})")
      end

      def enqueue_at(job, _timestamp) = enqueue(job)

      def enqueue_after_transaction_commit? = false
    end

    setup do
      EventRail::Current.reset
      [ StagedJob, RecipeOrder ].each(&:delete_all)
      RecipeRecord.connection.execute("DELETE FROM queue_rows")
      OtherRow.delete_all
    end

    teardown { EventRail::Current.reset }

    # --- staging inside a transaction, and the duplicate check ------------------------

    test "staging inside an open transaction is the point, not an error" do
      with_stager(StagedJob) do
        RecipeRecord.transaction do
          RecipeOrder.create!(state: "shipped")
          EventRail.stage(RecipeFixtures::Shipped.new(order_id: "o-1"))
        end
      end

      assert_equal 1, RecipeOrder.count
      assert_equal [ RecipeFixtures::Invoice, RecipeFixtures::Notify ].map(&:name).sort, enqueued_jobs.map { |job| job["job_class"] }.sort
      assert_equal 0, StagedJob.count, "handed over rows are deleted"
    end

    test "publishing a fact staged earlier in the same job attempt is a duplicate" do
      in_job(StagedJob) do
        RecipeRecord.transaction { EventRail.stage(RecipeFixtures::Shipped.new(order_id: "o-1")) }

        assert_raises(EventRail::DuplicatePublicationError) { EventRail.publish(RecipeFixtures::Shipped.new(order_id: "o-1")) }
      end
    end

    test "restaging after a rollback in the same job attempt is a duplicate" do
      in_job(StagedJob) do
        RecipeRecord.transaction do
          EventRail.stage(RecipeFixtures::Shipped.new(order_id: "o-1"))
          raise ActiveRecord::Rollback
        end

        assert_raises(EventRail::DuplicatePublicationError) do
          RecipeRecord.transaction { EventRail.stage(RecipeFixtures::Shipped.new(order_id: "o-1")) }
        end
      end
    end

    # --- the outbox recipe ----------------------------------------------------------

    test "the outbox refuses to stage outside a transaction, even an empty list" do
      assert_raises(ArgumentError) { StagedJob.stage([]) }
    end

    test "a rolled-back transaction stages nothing" do
      with_stager(StagedJob) do
        RecipeRecord.transaction do
          EventRail.stage(RecipeFixtures::Shipped.new(order_id: "o-1"))
          raise ActiveRecord::Rollback
        end
      end

      assert_equal 0, StagedJob.count
      assert_empty enqueued_jobs
    end

    test "a rescued failure leaves none of the list, and the business state still commits" do
      RecipeRecord.transaction { StagedJob.insert_all!([ { job_id: "taken", payload: {}, created_at: Time.current } ]) }
      jobs = [ RecipeFixtures::Invoice.new(nil), RecipeFixtures::Notify.new(nil) ]
      jobs.last.job_id = "taken"

      RecipeRecord.transaction do
        RecipeOrder.create!(state: "shipped")
        assert_raises(ActiveRecord::RecordNotUnique) { StagedJob.stage(jobs) }
      end

      assert_equal 1, RecipeOrder.count
      assert_equal [ "taken" ], StagedJob.pluck(:job_id), "the first job must not survive the second one's conflict"
    end

    test "a hand-over waits while another database's transaction is open" do
      with_stager(StagedJob) do
        OtherRecord.transaction do
          OtherRow.create!(name: "elsewhere")
          RecipeRecord.transaction { EventRail.stage(RecipeFixtures::Shipped.new(order_id: "o-1")) }

          assert_empty enqueued_jobs, "no job may leave while any transaction is still open"
          assert_equal 2, StagedJob.count
        end
      end

      assert_equal 2, enqueued_jobs.length
      assert_equal 0, StagedJob.count
    end

    test "when the other transaction rolls back, the rows stay for the relay" do
      with_stager(StagedJob) do
        OtherRecord.transaction do
          RecipeRecord.transaction { EventRail.stage(RecipeFixtures::Shipped.new(order_id: "o-1")) }
          raise ActiveRecord::Rollback
        end
      end

      assert_empty enqueued_jobs
      assert_equal 2, StagedJob.count

      StagedJob.relay(older_than: 0.seconds)

      assert_equal 2, enqueued_jobs.length
      assert_equal 0, StagedJob.count
    end

    test "a hand-over error after the commit is rescued and leaves the row" do
      failing_enqueue(RecipeFixtures::Notify) do
        with_stager(StagedJob) do
          RecipeRecord.transaction { EventRail.stage(RecipeFixtures::Shipped.new(order_id: "o-1")) }
        end
      end

      assert_equal [ "RecipeFixtures::Notify" ], StagedJob.all.map { |row| row.payload["job_class"] }
    end

    # --- the database-queue recipe --------------------------------------------------

    test "the queue recipe enqueues inside the transaction, and a rescued failure leaves none of the list" do
      queue = DatabaseQueue.new
      jobs = [ RecipeFixtures::Notify.new(nil), RecipeFixtures::Invoice.new(nil) ]
      originals = jobs.to_h { |job| [ job.class, job.class.queue_adapter ] }
      jobs.each { |job| job.class.queue_adapter = queue }

      queue.fail_on = 2
      RecipeRecord.transaction do
        RecipeOrder.create!(state: "shipped")
        assert_raises(ActiveRecord::StatementInvalid) { QueueStager.stage(jobs) }
      end

      assert_equal 1, RecipeOrder.count
      assert_equal 0, queue_rows, "the first job must not survive the second one's failure"
    ensure
      # The very adapter objects, not :test: a fresh test adapter is not the one enqueued_jobs reads.
      originals&.each { |job_class, adapter| job_class.queue_adapter = adapter }
    end

    # Checked against what Active Job actually does, not against the rule restated: each
    # value is set on the class, a job is enqueued inside a transaction, and whether the
    # adapter saw it before the commit is compared with what the recipe predicts. The adapter
    # asks to defer, which is what makes :default and friends interesting.
    test "the queue recipe's deferral rule matches Active Job's own for every setting" do
      job_class = RecipeFixtures::Notify
      original = job_class.enqueue_after_transaction_commit
      adapter = job_class.queue_adapter
      adapter.define_singleton_method(:enqueue_after_transaction_commit?) { true }

      [ :never, :always, :default, false, true ].each do |setting|
        job_class.enqueue_after_transaction_commit = setting
        immediate = nil
        ActiveJob.deprecator.silence do
          RecipeRecord.transaction do
            before = enqueued_jobs.length
            job_class.new(nil).enqueue
            immediate = enqueued_jobs.length > before
          end
        end

        assert_equal !immediate, QueueStager.deferred?(job_class),
          "#{setting.inspect} on Active Job #{ActiveJob.version}: Active Job #{immediate ? "enqueued at once" : "deferred"}"
      end
    ensure
      job_class.enqueue_after_transaction_commit = original
      adapter.singleton_class.send(:remove_method, :enqueue_after_transaction_commit?)
    end

    test "the queue recipe refuses a job whose enqueue would actually be deferred" do
      job_class = RecipeFixtures::Notify
      original = job_class.enqueue_after_transaction_commit
      job_class.enqueue_after_transaction_commit = ActiveJob.version < Gem::Version.new("8.0") ? :always : true

      RecipeRecord.transaction do
        assert_raises(ArgumentError) { QueueStager.stage([ job_class.new(nil) ]) }
      end
    ensure
      job_class.enqueue_after_transaction_commit = original
    end

    test "the relay leaves a row it cannot load and hands over the rows after it" do
      now = Time.current
      good = RecipeFixtures::Notify.new(nil)
      StagedJob.insert_all!([
        { job_id: "gone", payload: good.serialize.merge("job_class" => "RecipeFixtures::RenamedAway", "job_id" => "gone"),
          created_at: now - 2.minutes },
        { job_id: good.job_id, payload: good.serialize, created_at: now - 1.minute }
      ])

      StagedJob.relay(older_than: 0.seconds)

      assert_equal [ good.job_id ], enqueued_jobs.map { |job| job["job_id"] }
      assert_equal [ "gone" ], StagedJob.pluck(:job_id)
    end

    # The copies above are the README's recipes; this keeps them so. Only the stand-in for the
    # README's ApplicationRecord may differ.
    test "each recipe method here is the README's, line for line" do
      readme = File.read(File.expand_path("../../README.md", __dir__), encoding: "UTF-8")
      source = File.read(__FILE__, encoding: "UTF-8")

      [ "def self.stage(jobs)", "def self.hand_over(job)", "def self.relay", "def stage(jobs)", "def deferred?" ].each do |signature|
        documented = method_lines(readme, signature).map { |line| line.gsub("ApplicationRecord", "queue_record") }
        tested = method_lines(source, signature)

        refute_empty documented, "the README must define #{signature}"
        assert_equal documented, tested, "#{signature} differs from the README's"
      end
    end

    private
      def method_lines(text, signature)
        text[/^( *)#{Regexp.escape(signature)}.*?^\1end$/m].to_s.lines.map(&:strip).reject(&:empty?)
      end

      # Makes every instance of one job class fail to enqueue, then removes the override so the
      # class inherits its enqueue again.
      def failing_enqueue(job_class)
        job_class.define_method(:enqueue) { |*| raise IOError, "queue unreachable" }
        yield
      ensure
        job_class.remove_method(:enqueue)
      end

      def queue_rows
        RecipeRecord.connection.select_value("SELECT COUNT(*) FROM queue_rows")
      end

      def with_stager(value)
        config = Rails.application.config.event_rail
        original = config.stager
        config.stager = value
        yield
      ensure
        config.stager = original
      end

      def in_job(stager, &body)
        RecipeFixtures::Runner.body = body
        with_stager(stager) { RecipeFixtures::Runner.perform_now }
      end
  end
end
