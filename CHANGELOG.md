## [Unreleased]

## [0.2.0] - 2026-04-23

- Auto-detect OTel instrumentation gems via `use_all`
- Name Sidekiq job spans by worker class (via `job_class` attribute)
- Support both old and new OTel semantic convention property keys in dashboard queries
- Guard dashboard routes when sqlite3 is missing

## [0.1.1] - 2025-12-17

- Rename gem from caboose to flare
- Warn instead of raising when sqlite3 gem is missing
- Make sqlite3 an optional dependency for production compatibility

## [0.1.0] - 2025-12-17

- Initial release
