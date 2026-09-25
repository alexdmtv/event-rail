module Simulation
  class Settings < ApplicationRecord
    validates :orders_per_minute, numericality: { only_integer: true, in: 0..120 }
    validates :cancel_rate, :return_rate, numericality: { in: 0.0..1.0 }

    def self.current = first_or_create!
  end
end
