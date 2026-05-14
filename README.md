# Errorgap Ruby

Ruby notifier for Errorgap. It captures exceptions, normalizes backtraces, and sends notices to a Errorgap server.

## Installation

Add the gem to your application:

```ruby
gem "errorgap"
```

Then install:

```sh
bundle install
```

## Configuration

```ruby
require "errorgap"

Errorgap.configure do |config|
  config.endpoint = ENV.fetch("ERRORGAP_ENDPOINT", "http://127.0.0.1:3030")
  config.project_slug = ENV["ERRORGAP_PROJECT_SLUG"]
  config.project_id = ENV["ERRORGAP_PROJECT_ID"]
  config.api_key = ENV["ERRORGAP_API_KEY"]
  config.environment = ENV.fetch("RAILS_ENV", ENV.fetch("RACK_ENV", "development"))
end
```

## Manual Notification

```ruby
begin
  risky_operation
rescue => error
  Errorgap.notify(error, context: { component: "billing" })
  raise
end
```

## Rack

```ruby
use Errorgap::RackMiddleware
```

## Rails

In Rails, requiring the gem installs the Rack middleware automatically through the Railtie.

Generate an initializer:

```sh
rails generate errorgap:install
```

## Development

```sh
bundle install
bundle exec rake
```
