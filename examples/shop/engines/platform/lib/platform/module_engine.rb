module Platform
  module ModuleEngine
    # Every module's engine, Platform's included, in the order they load.
    def self.engines = @engines ||= []
    def self.extended(engine) = engines << engine

    # Rails runs an engine's migrations only once copied into the host by install:migrations;
    # this lets the host's db:migrate run them in place, in the module that owns the table.
    def share_migrations
      initializer "#{engine_name}.share_migrations" do |app|
        paths["db/migrate"].existent.each do |path|
          app.config.paths["db/migrate"] << path unless app.config.paths["db/migrate"].include?(path)
        end
      end
    end
  end
end
