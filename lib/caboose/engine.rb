# frozen_string_literal: true

module Caboose
  class Engine < ::Rails::Engine
    isolate_namespace Caboose

    # Serve static assets from the engine's public directory
    initializer "caboose.static_assets" do |app|
      app.middleware.use(
        Rack::Static,
        urls: ["/caboose-assets"],
        root: root.join("public"),
        cascade: true
      )
    end

    # Configure OpenTelemetry BEFORE middleware stack is built
    # This is critical - Rack instrumentation needs to insert its middleware
    initializer "caboose.opentelemetry", before: :build_middleware_stack do
      Caboose.configure_opentelemetry
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
