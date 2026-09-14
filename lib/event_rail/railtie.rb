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
  end
end
