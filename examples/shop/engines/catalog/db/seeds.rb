# A small catalog, priced so that loyalty points (one per whole euro) are easy to follow.
[
  [ "TEA-GREEN", "Green tea, 100 g", 890, 400 ],
  [ "TEA-BLACK", "Assam black tea, 100 g", 790, 400 ],
  [ "MUG-STONE", "Stoneware mug", 1490, 250 ],
  [ "POT-GLASS", "Glass teapot, 1 l", 3490, 120 ],
  [ "KETTLE-GOOSE", "Gooseneck kettle", 5990, 80 ],
  [ "SCALE-MINI", "Pocket scale", 2290, 150 ],
  [ "TIN-SET", "Set of three tins", 1990, 200 ],
  [ "FILTER-PACK", "Paper filters, 100 pcs", 390, 600 ]
].each do |sku, name, price_cents, on_hand|
  Catalog::Product.find_or_create_by!(sku: sku) do |product|
    product.name = name
    product.price_cents = price_cents
    product.on_hand = on_hand
  end
end
