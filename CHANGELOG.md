# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-07-10

### Added

- `config.ignore_environments` configuration option to skip all reporting
  (error notices and APM transactions) in the listed environments, e.g.
  `config.ignore_environments = %w[test development]`. Also configurable via
  the `ERRORGAP_IGNORE_ENVIRONMENTS` environment variable (comma-separated).
- `Errorgap::Configuration#ignored_environment?` helper.
- The Rails install generator initializer now includes `ignore_environments`
  with `test` and `development` ignored by default.

## [0.1.0] - 2026-07-09

### Added

- Initial release: exception capture with normalized backtraces, manual
  `Errorgap.notify`, Rack middleware, Rails Railtie and install generator.
- APM performance monitoring (opt-in via `config.apm_enabled`) with request
  timing and DB query spans, sampled by `config.apm_sample_rate`.
- Authentication via the `X-Errorgap-Project-Key` header.

[0.2.0]: https://github.com/errorgaphq/errorgap-ruby/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/errorgaphq/errorgap-ruby/releases/tag/v0.1.0
