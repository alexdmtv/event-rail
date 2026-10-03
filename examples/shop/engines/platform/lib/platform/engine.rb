require_relative "module_engine"

module Platform
  class Engine < ::Rails::Engine
    extend ModuleEngine

    isolate_namespace Platform
    share_migrations

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
