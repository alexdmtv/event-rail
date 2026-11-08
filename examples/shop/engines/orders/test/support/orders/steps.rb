module Orders
  # For Orders' own tests, which work with its records and run only Orders' jobs. Another module
  # moves only through its own test support, whose verbs run its jobs; what it then announces
  # reaches Orders' subscribers, which a step runs. Its state is read through its test support.
  module Steps
    CUSTOMER = TestSupport::CUSTOMER

    def checkout_order(**) = Order.find(TestSupport.checkout(**).id)
    def place_and_confirm_order(**) = Order.find(TestSupport.place_and_confirm(**).id)

    def available(sku) = Catalog::TestSupport.available(sku)
    def on_hand(sku) = Catalog::TestSupport.on_hand(sku)
    # Units of the product orders hold, without knowing how many Catalog has.
    def held(sku) = on_hand(sku) - available(sku)

    # Payments hears back from the provider on what it asked, captured, refunded or refused as the
    # test set the provider, and Orders hears what Payments announced.
    def payments_answer = Payments::TestSupport.provider_answers.then { hear_announcements }

    # The carrier collects, delivers or brings back the parcel, and Orders hears what Fulfillment
    # announced.
    def carrier_collects = Fulfillment::TestSupport.carrier_collects_parcels.then { hear_announcements }
    def carrier_delivers = Fulfillment::TestSupport.carrier_delivers_parcels.then { hear_announcements }
    def carrier_brings_back = Fulfillment::TestSupport.carrier_brings_back_parcels.then { hear_announcements }

    # Runs Orders' subscribers to what other modules announced, and nothing else.
    def hear_announcements(only: SUBSCRIBERS) = perform_enqueued_jobs(only: ->(job) { only.call(job.fetch(:job)) })
    SUBSCRIBERS = ->(job_class) { job_class < ApplicationJob && job_class.event_rail_subscriber? }

    # Delivers again the event a subscriber last heard, as a redelivery would, and fails if the
    # subscriber raised.
    def redeliver(subscriber)
      delivery = performed_jobs.reverse.find { |job| job[:job] == subscriber } or flunk "#{subscriber.name} heard nothing"
      perform_once(subscriber, *ActiveJob::Arguments.deserialize(delivery[:args]))
    end
  end
end
