module Billing
  class InvoiceIssued < EventRail::Event
    event_type "billing.invoice_issued"
    version 1
    default_source "event_rail.billing"

    attribute :invoice_id, :string
  end
end
