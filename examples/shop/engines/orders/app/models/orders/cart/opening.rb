module Orders
  class Cart
    # A client's request to open a cart, checked as a whole before anything is written, so the
    # client hears every problem at once: each detail of the customer that is missing, each
    # quantity that is not a whole number above zero, each product the shop does not sell. Its
    # errors are named by the request's own fields (customer.email, items.MUG), not by the
    # cart's columns, and Cart.open raises them as one Platform::InvalidInput.
    class Opening
      include ActiveModel::Validations

      CUSTOMER_FIELDS = %i[ id name email address ].freeze

      attr_reader :customer, :items

      validate :customer_is_complete, :items_are_quantities_of_products

      # customer: a Customer snapshot; items: { "sku" => quantity }, as Integers or the digits a
      # form submits. A quantity of zero is left out.
      def initialize(customer:, items:)
        @customer = customer
        @items = items.to_h.transform_keys(&:to_s)
      end

      # The quantities to add, by SKU, once the request is valid.
      def quantities = @quantities.to_h

      # The value at a field's path, which ActiveModel reads to build the field's message.
      def read_attribute_for_validation(field)
        group, key = field.to_s.split(".", 2)
        group == "customer" ? customer.public_send(key) : items[key]
      end

      private
        def customer_is_complete
          CUSTOMER_FIELDS.each { |field| errors.add(:"customer.#{field}", :blank) if customer.public_send(field).blank? }
          errors.add(:"customer.email", :invalid) if customer.email.present? && !customer.email.match?(URI::MailTo::EMAIL_REGEXP)
        end

        def items_are_quantities_of_products
          @quantities = {}
          items.each do |sku, input|
            next if input.to_s == "0"

            @quantities[sku] = Quantity.parse(input)
          rescue InvalidQuantity
            errors.add(:"items.#{sku}", :not_a_quantity, message: "is not a whole number above zero")
          end

          @quantities.each_key do |sku|
            Catalog::Api.product(sku)
          rescue Catalog::UnknownProduct
            errors.add(:"items.#{sku}", :unknown_product, message: "is not a product the shop sells")
          end
        end
    end
  end
end
