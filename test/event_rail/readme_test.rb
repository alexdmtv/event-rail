require "test_helper"

# The README's Ruby examples are executed, not proofread.
#
# Documentation that has drifted from the API is worse than none: it teaches the wrong
# thing confidently. Every fenced Ruby block runs here, in order, inside the fixture
# application, and a block that cannot run fails this test. Blocks that are not meant to
# run -- a Gemfile line, a snippet that assumes an application's own classes -- carry a
# `# doc:illustrative` marker and are skipped.
class ReadmeTest < ActiveSupport::TestCase
  README = File.expand_path("../../README.md", __dir__)

  setup { EventRail::Current.reset }
  teardown { EventRail::Current.reset }

  test "every runnable README example executes in the fixture application" do
    runnable, skipped = partition_examples

    assert_operator runnable.length, :>=, 6, "the README should carry real, runnable examples"
    # Raised from 5 with the test-helper section, whose examples are file-context by nature:
    # a `test/test_helper.rb`, a `config/application.rb` line, and a `test ... do` body that
    # needs the test case's own instance methods. The cap exists to stop marking a snippet
    # that could have run, not to cap how much of the README is a file rather than a script.
    assert_operator skipped.length, :<=, 7, "only genuinely unrunnable snippets should be marked"

    Registry.reopen do
      runnable.each_with_index do |example, index|
        # rubocop:disable Security/Eval
        eval(example, TOPLEVEL_BINDING, "#{README}:example-#{index + 1}")
        # rubocop:enable Security/Eval
      rescue StandardError, ScriptError => error
        flunk "README example #{index + 1} failed with #{error.class}: #{error.message}\n\n#{example}"
      end
    end

    Registry.prepare
  end

  test "the documented limits table matches the constants" do
    table = File.read(README)[/## Fixed safety limits.*?\n\n(\|.*?)\n\n/m, 1]

    refute_nil table, "the limits table must be present"
    assert_includes table, "512 bytes"
    assert_includes table, "1,024 bytes"
    assert_includes table, "8,192 bytes"
    assert_includes table, "| 32 |"
    assert_includes table, "64 bytes"
    assert_includes table, "255 bytes"
    assert_includes table, "| 32 |"

    assert_equal 512, EventRail::Limits::MAX_IDENTIFIER_BYTES
    assert_equal 1_024, EventRail::Limits::MAX_EXTENSION_VALUE_BYTES
    assert_equal 8_192, EventRail::Limits::MAX_EXTENSIONS_BYTES
    assert_equal 32, EventRail::Limits::MAX_RAW_DEPTH
    assert_equal 32, EventRail::Limits::MAX_EXTENSION_ENTRIES
    assert_equal 64, EventRail::Limits::MAX_EXTENSION_KEY_BYTES
  end

  test "the documented notification table names every notification the library emits" do
    table = File.read(README)[/## Notifications.*?\n\n\| Name.*?\n\n/m]

    refute_nil table
    %w[
      publish.event_rail enqueue_subscriber.event_rail deserialize.event_rail perform_subscriber.event_rail
    ].each { |name| assert_includes table, name }
    %w[subscriber_count accepted skipped job_class outcome format_version].each do |key|
      assert_includes table, key
    end
  end

  test "the README documents every operational topic an adopter has to know" do
    readme = File.read(README)

    {
      "Rails-only initialization" => "initializes itself through a Railtie",
      "at-least-once semantics" => "At-least-once delivery",
      "subscriber idempotency" => "must therefore be idempotent",
      "backend-owned retries and dead-lettering" => "dead-letter handling stay where they already are",
      "transaction deferral" => "enqueue_after_transaction_commit",
      "replay-safe publishers" => "Replay-safe publishers",
      "compatible versus breaking versions" => "Versioning events",
      "timestamp semantics" => "logical publication time",
      "source semantics" => "identifies a logical producer",
      "context and event extensions" => "durable baggage",
      "fixed limits" => "Fixed safety limits",
      "fiber isolation" => "isolation_level = :fiber",
      "private format staging" => "read-before-write deployments",
      "external allowlists" => "its own allowlist",
      "loop prevention" => "Loop prevention is application policy",
      "upgrade and rollback draining" => "drained or expired"
    }.each do |topic, evidence|
      assert_includes readme, evidence, "the README must document #{topic}"
    end
  end

  private
    def partition_examples
      blocks = File.read(README).scan(/```ruby\n(.*?)```/m).flatten

      blocks.partition { |block| !block.include?("# doc:illustrative") }
    end
end
