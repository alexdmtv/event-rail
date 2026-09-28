require "test_helper"

# The design rules that can be checked mechanically. Packwerk checks dependencies and privacy;
# these check the rest, by reflection over the loaded application.
class DesignRulesTest < ActiveSupport::TestCase
  setup { Rails.application.eager_load! }

  # The shop has one retry policy, in Platform::ApplicationJob, chosen by an error's category. A
  # job declaring its own would override it silently: Active Job consults the most recent
  # declaration first.
  test "no job declares a retry policy of its own" do
    base = Platform::ApplicationJob.rescue_handlers
    declaring = shop_jobs.select { |job| (job.rescue_handlers - base).any? }

    assert_empty declaring.map(&:name)
  end

  # A published event is a module's contract, in the package other modules may depend on.
  test "every event lives in its module's published events" do
    misplaced = shop_classes(EventRail::Event).reject { |event| source_of(event).match?(%r{/app/public/\w+/events/}) }

    assert_empty misplaced.map(&:name)
  end

  # A job holds no logic: it finds what it is about and calls one domain method.
  test "every job's perform is one line" do
    long = shop_jobs.reject { |job| job.name.start_with?("Platform::", "Observability::", "Simulation::") }.select do |job|
      file, line = job.instance_method(:perform).source_location
      File.readlines(file)[line - 1].exclude?("def perform") || File.readlines(file)[line - 1].exclude?(" = ")
    end

    assert_empty long.map(&:name), "a job whose perform is more than one line"
  end

  # Every task in config/recurring.yml names a job that exists, or a command, and a schedule
  # Solid Queue can parse. Solid Queue refuses to start with an invalid schedule; this finds a
  # renamed job in CI rather than at deploy.
  test "the recurring schedule is valid" do
    assert_empty schedule_problems
  end

  private
    def shop_jobs = shop_classes(Platform::ApplicationJob).select { |job| job.descendants.empty? }

    def shop_classes(base)
      base.descendants.select do |klass|
        path = klass.name && source_of(klass)
        path&.start_with?(Rails.root.to_s) && path.exclude?("/test/")
      end
    end

    def source_of(klass) = Object.const_source_location(klass.name)&.first.to_s
end
