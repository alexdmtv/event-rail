module EventRail
  class Railtie < ::Rails::Railtie
    # Preparation, not an initializer: it has to run again on every reload, and it has
    # to run after the main autoloader exists. Rails sets that loader up in a finisher
    # that runs after config/initializers and runs prepare callbacks before
    # eager_load!, so no reloadable constant outside a conventional root can already be
    # loaded here -- which is exactly why one declared there raises later instead of
    # silently receiving nothing.
    config.to_prepare do
      # Unqualified, so lexical lookup reaches the private Internal namespace that a
      # qualified EventRail::Internal reference would be refused.
      Internal::Registry.prepare
    end

    # A reload deletes the constants and only then runs prepare callbacks, and nothing
    # clears the snapshot in between -- so a declaration arriving in that window would be
    # rejected for lateness even though the imminent prepare would have registered it. That
    # window is reachable by any prepare callback ordered ahead of EventRail's, which is the
    # case for one registered directly on the reloader from an initializer, or belonging to
    # a gem that loads earlier in the Gemfile.
    #
    # An initializer rather than a prepare block: registering the callback from `prepare`
    # would add it again on every reload.
    initializer "event_rail.mark_reload_window" do |app|
      if app.config.reloading_enabled?
        app.reloader.before_class_unload { Internal::Registry.reloading! }
      end
    end
  end
end
