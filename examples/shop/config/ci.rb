# Run using bin/ci. The same steps as the `example` job in the gem's GitHub workflow.

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Tests: modules and flows", "bin/rails test test engines/*/test"
  step "Tests: console", "bin/rails test:system"
  step "Tests: seeds", "env RAILS_ENV=test bin/rails db:seed:replant"

  step "Boundaries: dependency graph", "bin/packwerk validate"
  step "Boundaries: references", "bin/packwerk check"
end
