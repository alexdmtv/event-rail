# Each module seeds its own data from its engine's db/seeds.rb.
Rails.application.railties.grep(Rails::Engine).each do |engine|
  engine.load_seed if engine.root.to_s.start_with?(Rails.root.join("engines").to_s)
end
