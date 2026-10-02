require_relative "module_engine"

module Platform
  # The bottom layer every module may depend on: the base classes the other modules' own
  # base classes inherit from, and the staged-jobs table. It depends on no other module.
  class Engine < ::Rails::Engine
    extend ModuleEngine

    isolate_namespace Platform
    share_migrations

    # Every error answer is problem details (RFC 9457), whoever renders it.
    initializer "platform.problem_details" do |app|
      require_relative "exceptions_app"
      Mime::Type.register "application/problem+json", :problem
      app.config.exceptions_app = Platform::ExceptionsApp
    end

    initializer "platform.error_subscriber" do
      require_relative "error_subscriber"
      Rails.error.subscribe(Platform::ErrorSubscriber.new)
    end
  end
end
