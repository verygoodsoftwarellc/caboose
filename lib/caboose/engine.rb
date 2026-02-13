# frozen_string_literal: true

module Caboose
  class Engine < ::Rails::Engine
    isolate_namespace Caboose

    # Load secrets from Rails credentials if not already set via ENV
    initializer "caboose.defaults", before: :load_config_initializers do |app|
      ENV["CABOOSE_KEY"] ||= app.credentials.dig(:caboose, :key)
    end

    # Serve static assets from the engine's public directory
    initializer "caboose.static_assets" do |app|
      app.middleware.use(
        Rack::Static,
        urls: ["/caboose-assets"],
        root: root.join("public"),
        cascade: true
      )
    end

    # Phase 1: Configure OTel SDK and instrumentations before middleware is
    # built so Rack/ActionPack can insert their middleware.
    initializer "caboose.opentelemetry", before: :build_middleware_stack do
      Caboose.configure_opentelemetry
    end

    # Phase 2: Start the metrics flusher after all initializers have run
    # so user config (metrics_enabled, flush_interval, etc.) is applied.
    config.after_initialize do
      Caboose.start_metrics_flusher
    end

    # Auto-mount routes in development/test
    initializer "caboose.routes", before: :add_routing_paths do |app|
      if Rails.env.development? || Rails.env.test?
        app.routes.prepend do
          mount Caboose::Engine => "/caboose"
        end
      end
    end
  end
end
