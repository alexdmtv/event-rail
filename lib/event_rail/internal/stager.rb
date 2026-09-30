module EventRail
  module Internal
    # Finds the application's stager: what `EventRail.stage` hands an event's subscriber
    # jobs to, in place of enqueuing them.
    #
    # Configured by name as a rule. A stager is usually an application model, which cannot be
    # loaded while `config/application.rb` or an initializer runs and is replaced on every
    # reload in development, so a class held by reference would either fail the boot or go
    # stale. The name is resolved again on every staging, the way `belongs_to` resolves
    # `class_name:`. An object is used as given, for a stager that is never reloaded.
    module Stager
      SETTING = "config.event_rail.stager".freeze
      # Ruby's own rule for a constant name, Unicode included: an uppercase letter, then word
      # characters.
      CONSTANT_PATH = /\A(?:::)?[[:upper:]][[:word:]]*(?:::[[:upper:]][[:word:]]*)*\z/

      module_function

      # The configured value, or a configuration error when there is no Rails application
      # to read it from: staging has nowhere else to find a stager.
      def configured
        unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application
          raise ConfigurationError,
            "EventRail.stage reads #{SETTING} from the Rails application, and there is none"
        end

        ::Rails.application.config.event_rail&.stager
      end

      def resolve(configured)
        if configured.nil?
          raise ConfigurationError,
            "EventRail.stage needs a stager; set #{SETTING} to the name of a class that responds to stage(jobs)"
        end

        stager = configured.is_a?(String) || configured.is_a?(Symbol) ? constantize(configured.to_s) : configured
        return stager if stager.respond_to?(:stage)

        raise ConfigurationError, "#{SETTING} is #{configured.inspect}, which does not respond to stage(jobs)"
      end

      # Called from preparation, which runs after the autoloaders are set up and again on
      # every reload, so a misspelled name or a missing method fails the boot that
      # introduced it rather than the first staging. Nothing to check without a Rails
      # application, or with no stager configured: an application that never stages needs
      # none.
      def validate!
        return unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

        value = configured
        resolve(value) unless value.nil?
      end

      # Only a constant the name itself denotes being missing is a configuration error: the
      # name, or one of the namespaces it passes through. That is decided by where the lookup
      # failed -- which constant was missing, and in which namespace -- rather than by comparing
      # strings, so a name that passes through an alias of a namespace is judged by the
      # namespace it reaches. Anything else raised while loading the stager is a bug in its
      # file, left alone so its backtrace points there: a NameError naming no constant, one
      # missing from some other namespace, or Zeitwerk's, which means the file exists and
      # defines the wrong thing.
      def constantize(name)
        unless name.match?(CONSTANT_PATH)
          raise ConfigurationError, "#{SETTING} is #{name.inspect}, which is not a constant name"
        end

        ActiveSupport::Inflector.constantize(name)
      rescue NameError => error
        raise if defined?(::Zeitwerk::NameError) && error.is_a?(::Zeitwerk::NameError)
        raise unless missing_from(name, error)

        raise ConfigurationError, "#{SETTING} names #{name.inspect}, which is not a constant"
      end

      def missing_from(name, error)
        return false if error.name.nil?

        receiver = begin
          error.receiver
        rescue ArgumentError
          return false # raised by hand, with no namespace it was looked up in
        end

        segments = name.delete_prefix("::").split("::")
        segments.each_index.any? do |index|
          segments[index] == error.name.to_s && namespace(segments.first(index)).equal?(receiver)
        end
      end

      def namespace(segments)
        return Object if segments.empty?

        ActiveSupport::Inflector.constantize(segments.join("::"))
      rescue NameError
        nil
      end
    end
  end
end
