require "test_helper"
require "open3"
require "rbconfig"

class DummyBootTest < ActiveSupport::TestCase
  BOOT_SCRIPT = <<~'RUBY'
    require File.expand_path("test/dummy/config/environment", Dir.pwd)

    expected_roots = [
      "test/dummy/app/events",
      "test/dummy/app/jobs",
      "test/dummy/engines/orders/app/events",
      "test/dummy/engines/orders/app/jobs",
      "test/dummy/engines/billing/app/events",
      "test/dummy/engines/billing/app/jobs"
    ].map { |path| File.expand_path(path, Dir.pwd) }

    missing = expected_roots - Rails.autoloaders.main.dirs.map(&:to_s)
    abort "missing loader roots: #{missing.join(", ")}" unless missing.empty?
    abort "Active Record unexpectedly loaded" if defined?(ActiveRecord::Base)

    puts ActiveJob::Base.queue_adapter.class.name
  RUBY

  test "minimal fixture boots lazily with the test adapter" do
    output = boot_dummy(eager_load: false, adapter: "test")

    assert_includes output, "ActiveJob::QueueAdapters::TestAdapter"
  end

  test "minimal fixture boots eagerly with the async adapter" do
    output = boot_dummy(eager_load: true, adapter: "async")

    assert_includes output, "ActiveJob::QueueAdapters::AsyncAdapter"
  end

  private
    def boot_dummy(eager_load:, adapter:)
      env = {
        "RAILS_ENV" => "test",
        "DUMMY_EAGER_LOAD" => eager_load.to_s,
        "ACTIVE_JOB_QUEUE_ADAPTER" => adapter
      }
      output, error, status = Open3.capture3(
        env,
        RbConfig.ruby,
        "-Ilib",
        "-e",
        BOOT_SCRIPT,
        chdir: File.expand_path("..", __dir__)
      )

      assert status.success?, error
      output
    end
end
