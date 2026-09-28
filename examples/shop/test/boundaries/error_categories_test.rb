require "test_helper"

# Every error the shop raises says what a caller should do about it, by including one of
# Platform's categories (see Platform::ErrorCategory). A base class that only groups a module's
# errors needs none.
class ErrorCategoriesTest < ActiveSupport::TestCase
  # Raised by the console's fault switch to stand in for a failure nobody has classified.
  UNCLASSIFIED_BY_DESIGN = %w[ Platform::InjectedFault ].freeze

  test "every error the shop defines includes a category" do
    Rails.application.eager_load!

    missing = shop_errors.reject { |error| error.descendants.any? || UNCLASSIFIED_BY_DESIGN.include?(error.name) }
      .select { |error| Platform::ErrorCategory::ALL.none? { |category| error <= category } }

    assert_empty missing.map(&:name), "errors without a category"
  end

  private
    def shop_errors
      root = Rails.root.to_s
      StandardError.descendants.select do |error|
        path = error.name && Object.const_source_location(error.name)&.first.to_s
        path&.start_with?(root) && path.exclude?("/test/")
      end
    end
end
