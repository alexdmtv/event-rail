module Platform
  # What every module engine shares, kept here rather than copied into each engine.
  module ModuleEngine
    # Rails runs an engine's migrations only after they are copied into the host with
    # `<engine>:install:migrations`. Appending the engine's own directory instead lets the
    # host's db:migrate run them in place, so a migration lives with the module that owns
    # its table.
    def share_migrations
      initializer "#{engine_name}.share_migrations" do |app|
        paths["db/migrate"].existent.each do |path|
          app.config.paths["db/migrate"] << path unless app.config.paths["db/migrate"].include?(path)
        end
      end
    end
  end
end
