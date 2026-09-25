require "test_helper"
require "capybara/cuprite"

# Headless Chrome through the DevTools protocol. Set BROWSER_PATH when Chrome is not where
# Ferrum looks for it. The sandbox is off because containers and CI runners often cannot
# provide it, and this browser only ever loads the application under test.
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :cuprite, screen_size: [ 1280, 800 ], options: {
    browser_path: ENV["BROWSER_PATH"], browser_options: { "no-sandbox" => nil }, process_timeout: 30, timeout: 15
  }.compact

  include ShopHelpers

  setup { stock_shelves }
end
