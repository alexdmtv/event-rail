module Observability
  class Node < ApplicationRecord
    has_many :attempts, -> { order(:number, :id) }, primary_key: :node_id, foreign_key: :job_id, inverse_of: false

    scope :events, -> { where(kind: "event") }
    scope :jobs, -> { where(kind: "job") }
  end
end
