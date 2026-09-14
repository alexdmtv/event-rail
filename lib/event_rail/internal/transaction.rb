module EventRail
  module Internal
    # Detects an open application database transaction without depending on Active
    # Record.
    #
    # `ActiveRecord.after_all_transactions_commit` runs its block synchronously when no
    # transaction is open and defers it to commit when one is, so calling it with a
    # block that records whether it ran answers the question using only Active Record's
    # public API -- no connection pool, no internal transaction manager, and nothing at
    # all when Active Record is absent.
    module Transaction
      module_function

      def check!
        return unless open?

        raise TransactionalPublicationError
      end

      def open?
        return false unless defined?(::ActiveRecord) && ::ActiveRecord.respond_to?(:after_all_transactions_commit)

        deferred = true
        ::ActiveRecord.after_all_transactions_commit { deferred = false }
        deferred
      rescue StandardError
        # Active Record is loaded but not usable -- no connection configured, for
        # instance. Publication is not the place to turn that into a failure.
        false
      end
    end
  end
end
