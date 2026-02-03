# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Caboose
  module Generators
    class MetricsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Create migration for Caboose metrics table"

      def create_migration_file
        migration_template(
          "create_caboose_metrics.rb.erb",
          "db/migrate/create_caboose_metrics.rb"
        )
      end

      def display_post_install_message
        say ""
        say "Caboose metrics migration created!", :green
        say ""
        say "Next steps:"
        say "  1. Run: rails db:migrate"
        say "  2. Enable metrics in config/initializers/caboose.rb:"
        say "     config.metrics_enabled = true"
        say ""
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
