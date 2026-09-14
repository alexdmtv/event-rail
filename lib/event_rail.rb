require "active_job"
require "active_model"
require "active_support"
require "rails/railtie"

require "event_rail/version"
require "event_rail/errors"
require "event_rail/limits"
require "event_rail/portable_type"
require "event_rail/internal/portable_value"
require "event_rail/internal/extensions"
require "event_rail/internal/types"
require "event_rail/internal/attribute_record"
require "event_rail/data"
require "event_rail/internal/timestamp"
require "event_rail/metadata"
require "event_rail/event"
require "event_rail/internal/contract_index"
require "event_rail/internal/identity"
require "event_rail/internal/execution"
require "event_rail/current"
require "event_rail/internal/context"
require "event_rail/job_context"
require "event_rail/internal/notifications"
require "event_rail/internal/subscriber_execution"
require "event_rail/subscriptions"
require "event_rail/internal/registry"
require "event_rail/internal/stamping"
require "event_rail/contract"
require "event_rail/envelope"
require "event_rail/internal/event_serializer"
require "event_rail/internal/transaction"
require "event_rail/publication"
require "event_rail/publish"
require "event_rail/railtie"

# The subscription macro is class-level only: it changes nothing about serialization
# or execution for a job that never calls it. Registering the hook here rather than in
# an initializer means it is in place before Active Job loads, in a Rails application
# and in a plain Ruby process alike.
ActiveSupport.on_load(:active_job) do
  extend EventRail::Subscriptions

  # Registering here rather than in an initializer keeps the serializer available to a
  # plain Ruby process too, and it is registered exactly once because the load hook runs
  # once.
  ActiveJob::Serializers.add_serializers(EventRail.const_get(:Internal)::EventSerializer)
end

module EventRail
  private_constant :Internal
end
