require "test_helper"

class ReadmeGuideTest < ActiveSupport::TestCase
  test "the guide lists every cross-module call and subscription" do
    guide = Rails.root.join("README.md").read[/^## What goes where$.*?(?=^## )/m]
    assert guide, "README.md has no \"What goes where\" section"

    interactions = cross_module_interactions
    assert_includes interactions, "Payments::Api.request_capture", "the extraction found no cross-module calls"
    assert_includes interactions, "subscribes_to Orders::Events::OrderDelivered", "the extraction found no subscriptions"

    missing = interactions.reject { |interaction| guide.include?("| `#{interaction}` |") }
    assert_empty missing, "README.md's guide does not explain: #{missing.join(", ")}"
  end

  private
    def cross_module_interactions
      Dir[Rails.root.join("engines/*/app/**/*.rb")].flat_map do |path|
        owner = path[%r{engines/(\w+)/}, 1].camelize
        source = File.read(path)
        calls = source.scan(/\b(\w+)::Api\.(\w+)/).map { |target, method| [ target, "#{target}::Api.#{method}" ] }
        subscriptions = source.scan(/subscribes_to\s+((?:[\w:]+,\s*)*[\w:]+)/).flat_map do |(list)|
          list.scan(/(\w+)::Events::(\w+)/).map { |target, event| [ target, "subscribes_to #{target}::Events::#{event}" ] }
        end
        (calls + subscriptions).reject { |target, _| target == owner }.map(&:last)
      end.uniq.sort
    end
end
