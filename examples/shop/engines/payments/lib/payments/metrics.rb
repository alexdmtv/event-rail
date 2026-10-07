module Payments
  # The provider's answers and how long they take, by operation and outcome: a histogram counts
  # its observations too, so it gives the refusal and failure rates as well.
  module Metrics
    Yabeda.configure do
      group :payments
      histogram :gateway_call_duration_seconds, tags: %i[ operation outcome ], unit: :seconds,
        buckets: [ 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30 ], comment: "Calls to the payment provider"
    end

    class GatewayCalls < Platform::Metrics::Subscriber
      attach_to :payments

      def call_gateway(event)
        # A refusal raises too, but names its outcome; anything else raised is a failure.
        outcome = event.payload[:outcome] || "failed"
        Yabeda.payments.gateway_call_duration_seconds.measure({ operation: event.payload[:operation], outcome: }, event.duration / 1000.0)
      end
    end
  end
end
