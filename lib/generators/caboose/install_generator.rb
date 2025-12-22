# frozen_string_literal: true

module Caboose
  module Generators
    class InstallGenerator < Rails::Generators::Base
      desc "Install Caboose"

      def create_initializer
        create_file "config/initializers/caboose.rb", initializer_content
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

          # Only configure if Caboose is loaded (typically development only)
          if defined?(Caboose)
            Caboose.configure do |config|
              # Enable or disable Caboose (default: true)
              # config.enabled = true

              # How long to keep spans in hours (default: 24)
              # config.retention_hours = 24

              # Maximum number of spans to store (default: 5000)
              # config.max_spans = 5000

              # Path to the SQLite database (default: db/caboose.sqlite3)
              # config.database_path = Rails.root.join("db", "caboose.sqlite3").to_s

              # Ignore specific requests (receives a Rack::Request, return true to ignore)
              # config.ignore_request = ->(request) {
              #   request.path.start_with?("/health")
              # }

              # Subscribe to custom notification prefixes (default: ["app."])
              # config.subscribe_patterns << "mycompany."
            end
          end

          # =============================================================================
          # Custom Instrumentation
          # =============================================================================
          #
          # Just use ActiveSupport::Notifications.instrument with an "app." prefix
          # anywhere in your code. It works in all environments - in production it's
          # a no-op, in development Caboose automatically captures it.
          #
          #   ActiveSupport::Notifications.instrument("app.geocoding", address: address) do
          #     geocoder.lookup(address)
          #   end
          #
          #   ActiveSupport::Notifications.instrument("app.stripe.charge", amount: 1000) do
          #     Stripe::Charge.create(...)
          #   end
        RUBY
      end
    end
  end
end
