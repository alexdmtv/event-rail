# Orders' own tests may read Orders' own records; this lives inside the Orders package so
# the boundary check agrees.
module OrderRecords
  def order_record(order) = Orders::Order.find(order.id)
end
