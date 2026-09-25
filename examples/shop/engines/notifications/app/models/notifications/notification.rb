module Notifications
  class Notification < ApplicationRecord
    scope :recent, -> { order(created_at: :desc) }
  end
end
