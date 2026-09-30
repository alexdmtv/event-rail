appraise "rails-7.2" do
  gem "activejob", "~> 7.2.0"
  gem "activemodel", "~> 7.2.0"
  gem "activesupport", "~> 7.2.0"
  gem "railties", "~> 7.2.0"
end

appraise "rails-8.0" do
  gem "activejob", "~> 8.0.0"
  gem "activemodel", "~> 8.0.0"
  gem "activesupport", "~> 8.0.0"
  gem "railties", "~> 8.0.0"
  # Active Support 8.0's JSON encoder still passes `quirks_mode:` to `JSON.generate`, which
  # json 3.0 removed, so an Active Record JSON column cannot be written with json 3 on this
  # leg. The staging recipes' outbox table has one. Pinned as gemfiles/adapters.gemfile is.
  gem "json", "~> 2.7"
end

appraise "rails-8.1" do
  gem "activejob", "~> 8.1.0"
  gem "activemodel", "~> 8.1.0"
  gem "activesupport", "~> 8.1.0"
  gem "railties", "~> 8.1.0"
end
