source "https://rubygems.org"

# Specify your gem's dependencies in event_rail.gemspec.
gemspec

gem "appraisal", "~> 2.5", require: false
gem "bundler", "2.6.9"
gem "minitest", "~> 6.0"
# minitest 6 removed `minitest/mock`. The suite stubs a singleton method in five places
# to reach failure paths no real adapter or loader produces on demand: an adapter that
# reports failure through `enqueue_error`, one that raises, a Zeitwerk loader that
# raises, and the guarantee that publication never calls `perform_all_later`. This is
# the same author's extraction of that file, version-continuous with minitest 5.
gem "minitest-mock", "~> 5.27"
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
