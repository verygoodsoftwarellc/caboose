# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "fileutils"
require "tmpdir"

# Load OpenTelemetry first
require "opentelemetry/sdk"

# Don't load Rails engine for unit tests - just test the core library
require "caboose/version"
require "caboose/configuration"
require "caboose/sqlite_exporter"
require "caboose/storage"
