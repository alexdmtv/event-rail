require "active_job"
require "active_model"
require "active_support"
require "rails/railtie"

require "event_rail/version"
require "event_rail/errors"
require "event_rail/limits"
require "event_rail/internal/portable_value"
require "event_rail/internal/types"
require "event_rail/internal/attribute_record"
require "event_rail/data"
require "event_rail/internal/timestamp"
require "event_rail/metadata"
require "event_rail/event"
require "event_rail/internal/contract_index"
require "event_rail/railtie"

module EventRail
  private_constant :Internal
end
