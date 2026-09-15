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
