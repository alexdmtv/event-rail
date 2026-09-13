# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = ENV.fetch("DUMMY_EAGER_LOAD", "false") == "true"
  config.cache_store = :null_store
  config.active_support.deprecation = :stderr
end
