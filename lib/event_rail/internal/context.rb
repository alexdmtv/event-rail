module EventRail
  module Internal
    # Installs lineage for the duration of a block and restores exactly what was
    # there before.
    #
    # The restore is manual rather than `CurrentAttributes#set`, because the values
    # have to survive nested in-process execution. The Rails executor resets current
    # attributes around `ActiveJob::Base.execute`, but a job performed inside another
    # -- the test adapter, the inline adapter, any `perform_now` -- never passes
    # through the executor, so without an explicit restore the inner job's lineage
    # would still be installed when the outer job resumes.
    module Context
      module_function

      FIELDS = [ :message_id, :correlation_id, :causation_id, :originated_at, :extensions ].freeze

      def establish(message_id:, correlation_id:, causation_id:, originated_at:, extensions:)
        previous = FIELDS.to_h { |field| [ field, Current.public_send(field) ] }

        Current.message_id = message_id
        Current.correlation_id = correlation_id
        Current.causation_id = causation_id
        Current.originated_at = originated_at
        Current.extensions = extensions

        yield
      ensure
        previous.each { |field, value| Current.public_send(:"#{field}=", value) }
      end
    end
  end
end
