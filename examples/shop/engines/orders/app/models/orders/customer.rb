module Orders
  # A snapshot of who is buying, kept on the cart and the order. The shop has no customer
  # module; the client says who is buying.
  Customer = Data.define(:id, :name, :email, :address)
end
