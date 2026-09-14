class ApplicationJob < ActiveJob::Base
  include EventRail::JobContext
end
