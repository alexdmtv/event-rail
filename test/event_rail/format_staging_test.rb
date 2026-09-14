require "test_helper"

Registry.reopen do
  module StagingFixtures
    class Placed < EventRail::Event
      event_type "tests.staging_placed"
      version 1
      default_source "acme.orders"

      attribute :order_id, :string
      attribute :total, :decimal
      attribute :placed_on, :date
      attribute :placed_at, :datetime
      identity_by :order_id
    end
  end
end

Registry.prepare

# How a private format is allowed to change.
#
# Format 2 here is synthetic: it exists only in this file, to exercise the deployment
# discipline rather than to introduce a real second format. It differs *structurally* --
# metadata moves under a shorter key -- and deliberately not in how any individual value
# is written, because that encoding is shared with the public envelope and changing it is
# a breaking public change rather than a private format bump.
module StagedReleases
  SERIALIZER = EventRailInternal::EventSerializer

  # Step one, deployed everywhere first: reads both formats, still writes the old one.
  class Reader < SERIALIZER
    def supported_format_versions
      [ 1, 2 ]
    end

    def format_version
      1
    end

    def deserialize(hash)
      hash["format"] == 2 ? super(downgrade(hash)) : super
    end

    private
      def downgrade(hash)
        hash.except("meta").merge("format" => 1, "metadata" => hash.fetch("meta"))
      end
  end

  # Step two, only after step one is everywhere: starts writing the new format.
  class Writer < Reader
    def format_version
      2
    end

    def serialize(event)
      written = super
      written.except("metadata").merge("format" => 2, "meta" => written.fetch("metadata"))
    end
  end

  # Step three, only after every queued message in a retired format is drained or
  # expired: the old reader may be removed. Formats still listed here are still in
  # flight, so the release that drops one of them is a bug, and this list is what makes
  # that assertion possible rather than a matter of memory.
  FORMATS_STILL_IN_FLIGHT = [ 1, 2 ].freeze
  FORMATS_DRAINED = [].freeze
end

class FormatStagingTest < ActiveSupport::TestCase
  Serializer = EventRailInternal::EventSerializer

  INPUT = {
    order_id: "o-1",
    total: "12.50",
    placed_on: "2026-09-01",
    placed_at: "2026-09-01T10:30:00.123456+02:00"
  }.freeze

  setup { EventRail::Current.reset }
  teardown { EventRail::Current.reset }

  test "the reader release accepts both formats while still writing the old one" do
    event = published
    old_form = Serializer.serialize(event)
    new_form = StagedReleases::Writer.serialize(event)

    assert_equal 1, StagedReleases::Reader.serialize(event).fetch("format"),
      "a reader release must not start writing the new format"
    assert_equal event, StagedReleases::Reader.deserialize(old_form)
    assert_equal event, StagedReleases::Reader.deserialize(new_form)
  end

  test "the writer release switches format without changing any value's encoding" do
    event = published
    old_form = Serializer.serialize(event)
    new_form = StagedReleases::Writer.serialize(event)

    refute_equal old_form.keys.sort, new_form.keys.sort, "the structure is what a format bump changes"
    assert_equal old_form.fetch("data"), new_form.fetch("data"),
      "a change to how a value is written is a breaking public change, not a private format bump"
    assert_equal old_form.fetch("metadata"), new_form.fetch("meta")
  end

  test "the shipped release cannot read a format no release has staged" do
    event = published
    unstaged = Serializer.serialize(event).merge("format" => 3)

    assert_raises(EventRail::UnsupportedFormatError) { StagedReleases::Reader.deserialize(unstaged) }
  end

  test "the release that drops a reader for a format still in flight is a bug" do
    supported = StagedReleases::Reader.instance.supported_format_versions

    StagedReleases::FORMATS_STILL_IN_FLIGHT.each do |format|
      assert_includes supported, format,
        "format #{format} may still be queued, so its reader cannot be removed yet"
    end
    StagedReleases::FORMATS_DRAINED.each do |format|
      refute_includes StagedReleases::FORMATS_STILL_IN_FLIGHT, format,
        "a format cannot be both drained and in flight"
    end
  end

  test "the shipped serializer writes a format it can also read" do
    assert_includes Serializer.instance.supported_format_versions, Serializer.instance.format_version
  end

  # The job context entry carries its own version for the same reason and evolves under
  # the same discipline.
  test "the job context entry version is staged separately from the event format" do
    assert_includes EventRail::JobContext::SUPPORTED_ENTRY_VERSIONS, EventRail::JobContext::ENTRY_VERSION
    refute_equal EventRail::JobContext, Serializer,
      "the two versions are independent, so one may move without the other"
  end

  test "a job context entry version no release has staged is refused before perform" do
    job_class = Class.new(ActiveJob::Base) do
      include EventRail::JobContext

      def self.name
        "StagingFixtures::ContextJob"
      end

      def perform; end
    end

    data = job_class.new.serialize
    data[EventRail::JobContext::ENTRY_KEY] = { "v" => 99 }

    assert_raises(EventRail::UnsupportedFormatError) { job_class.new.deserialize(data) }
  end

  private
    def published
      EventRail.publish(StagingFixtures::Placed.new(**INPUT)).event
    end
end
