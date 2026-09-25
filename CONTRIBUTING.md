# Contributing

EventRail is under initial development. Please open an issue before proposing a substantial API change.

Run `bin/test` and `bin/rubocop` before submitting a change.

To run the suite against a specific Rails version, generate the per-Rails gemfiles first
-- they are derived from the root `Gemfile` and are not committed:

```sh
bundle exec appraisal generate
bundle exec appraisal install
BUNDLE_GEMFILE=gemfiles/rails_7.2.gemfile bundle exec rake test
```

## The example application

`examples/shop` runs against the gem's own source, and CI's `example` job runs its tests and
its packwerk boundary checks on every pull request. A change that breaks the example fails the
build: fix the example in the same pull request. Run what the job runs with:

```sh
cd examples/shop
bin/setup --skip-server
bin/rails test test engines/*/test   # every test, the console's system tests included
bin/packwerk validate && bin/packwerk check
```

`bin/dev` starts the shop with its job workers; the console is at http://localhost:3000.
