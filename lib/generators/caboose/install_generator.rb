# frozen_string_literal: true

module Caboose
  module Generators
    class InstallGenerator < Rails::Generators::Base
      desc "Install Caboose"

      def create_initializer
        initializer_path = Rails.root.join("config", "initializers", "caboose.rb")

        if File.exist?(initializer_path)
          say_status :skip, "config/initializers/caboose.rb already exists", :yellow
        else
          create_file initializer_path, initializer_content
          say_status :create, "config/initializers/caboose.rb", :green
        end
      end

      def add_gitignore_entry
        gitignore_path = Rails.root.join(".gitignore")
        return unless File.exist?(gitignore_path)

        gitignore_content = File.read(gitignore_path)
        entry = "/db/caboose.sqlite3*"

        if gitignore_content.include?(entry)
          say_status :skip, ".gitignore already contains #{entry}", :yellow
        else
          append_to_file gitignore_path, "\n# Caboose development database\n#{entry}\n"
          say_status :append, ".gitignore", :green
        end
      end

      private

      def initializer_content
        <<~RUBY
          # frozen_string_literal: true

          Caboose.configure do |config|
            # Enable or disable Caboose (default: true)
            # config.enabled = true

            # How long to keep cases in hours (default: 24)
            # config.retention_hours = 24

            # Maximum number of cases to store (default: 1000)
            # config.max_cases = 1000

            # Path to the SQLite database (default: db/caboose.sqlite3)
            # config.database_path = Rails.root.join("db", "caboose.sqlite3").to_s

            # Events to ignore (these are ignored by default):
            # config.ignore = %w[
            #   render_partial.action_view
            #   render_collection.action_view
            #   render_layout.action_view
            #   logger.action_view
            #   process_middleware.action_dispatch
            #   start_processing.action_controller
            #   process_action.action_controller
            # ]

            # Add additional events to ignore:
            # config.ignore << "some_event.to_ignore"
          end
        RUBY
      end
    end
  end
end
