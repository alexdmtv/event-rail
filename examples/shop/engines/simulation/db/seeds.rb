# The customers the simulator and the console's order form shop as.
[
  [ "Ada Lovelace", "London" ], [ "Alan Turing", "Manchester" ], [ "Grace Hopper", "Arlington" ],
  [ "Katherine Johnson", "Hampton" ], [ "Edsger Dijkstra", "Nuenen" ], [ "Barbara Liskov", "Cambridge" ],
  [ "Donald Knuth", "Stanford" ], [ "Margaret Hamilton", "Boston" ], [ "Ken Thompson", "Menlo Park" ],
  [ "Frances Allen", "Peru, NY" ], [ "Tony Hoare", "Oxford" ], [ "Radia Perlman", "Redmond" ]
].each_with_index do |(name, city), index|
  Simulation::Customer.find_or_create_by!(customer_id: "cus_#{index + 1}") do |customer|
    customer.name = name
    customer.email = "#{name.downcase.split.first}@example.com"
    customer.address = "#{index + 1} Example Street, #{city}"
  end
end
