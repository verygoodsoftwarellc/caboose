# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Caboose
  module Generators
    class MetricsRollupsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Create migration for Caboose metrics rollup tables (hours and days)"

      def create_migration_file
        migration_template(
          "create_caboose_metrics_rollups.rb.erb",
          "db/migrate/create_caboose_metrics_rollups.rb"
        )
      end

      def display_post_install_message
        say ""
        say "Caboose metrics rollup tables migration created!", :green
        say ""
        say "Next steps:"
        say "  1. Run: rails db:migrate"
        say "  2. Set up a recurring job to run Caboose::MetricRollup.run!"
        say "     (e.g., hourly via cron, Sidekiq scheduler, or GoodJob)"
        say ""
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
