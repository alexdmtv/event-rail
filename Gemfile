source "https://rubygems.org"

# Specify your gem's dependencies in event_rail.gemspec.
gemspec

gem "appraisal", "~> 2.5", require: false
gem "bundler", "2.6.9"
# Held below 6.0 by the Rails 7.2 compatibility floor, not by choice. minitest 6 changed
# the arity of `Runnable.run`, and railties 7.2's `LineFiltering#run` override still takes
# the old one -- `wrong number of arguments (given 3, expected 1..2)` before a single test
# runs. Rails 8.0 and 8.1 are fine with it. Revisit when the floor moves to 8.0; minitest 6
# also drops `minitest/mock`, which test_helper.rb requires, so the same change needs
# `minitest-mock` added.
gem "minitest", "~> 5.25"
gem "rake", "~> 13.2"

# Task 6.6 detects an open application database transaction without depending on
# Active Record, which needs a fixture that actually has one. The primary dummy
# application has no database on purpose.
gem "activerecord", ">= 7.2", "< 9"
gem "sqlite3", ">= 2.1"
gem "ruby-lsp-rails", require: false, group: :development

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", "~> 1.1", require: false

# Start debugger with binding.b [https://github.com/ruby/debug]
# gem "debug", ">= 1.0.0"
