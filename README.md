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

  # Skip reporting entirely (errors and APM) in these environments.
  # Also configurable via ERRORGAP_IGNORE_ENVIRONMENTS="test,development".
  config.ignore_environments = %w[test development]
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

`Errorgap.notify` walks the exception's `cause` chain: each cause is reported
under `context.causes` and its frames are merged into one backtrace. Source
excerpts are attached to readable app **and** dependency frames.

## Breadcrumbs

```ruby
Errorgap.add_breadcrumb("received request", category: "http")
Errorgap.add_breadcrumb("loaded order", category: "db", metadata: { id: 7 })
# ...later notices include the trail above
```

The buffer keeps the most recent `config.max_breadcrumbs` entries (default 25);
`Errorgap.clear_breadcrumbs` empties it.

## Structured logs

```ruby
Errorgap.log("payment captured", level: "info", source: "payments")
```

Levels are `trace < debug < info < warn < error < fatal` (with aliases like
`warning`/`critical`); anything below `config.minimum_log_level` (default
`info`) is dropped locally. Set `config.logs_enabled = false` to disable.

## APM

The Rack middleware records a web transaction per request automatically (with
`sql.active_record` and view spans). To time work manually — or in a plain Ruby
app or background job — use the block API:

```ruby
Errorgap.track_transaction(method: "GET", path: "/orders/{id}", path_raw: "/orders/7", status_code: 200) do |spans|
  spans.database("SELECT * FROM orders WHERE id = 7", 4.2, fn_name: "Repo.load")
  spans.external(30.0, fn_name: "Gateway.fetch")
end

Errorgap.track_job("ReceiptJob", queue: "mailers") do |spans|
  spans.database("SELECT total FROM receipts WHERE id = 1", 3.1)
end
```

Enable with `config.apm_enabled = true` (and optionally `config.apm_sample_rate`).
Call `Errorgap.flush` before process exit to drain async deliveries.

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
