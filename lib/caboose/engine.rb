# frozen_string_literal: true

module Caboose
  class Engine < ::Rails::Engine
    isolate_namespace Caboose

    config.app_middleware.use(
      Rack::Static,
      urls: ["/caboose-assets"],
      root: root.join("public"),
      cascade: true
    )

    initializer "caboose.middleware" do |app|
      app.middleware.insert_before 0, Caboose::Middleware
    end

    initializer "caboose.subscriber" do
      # Subscribe to all notifications unconditionally
      # The subscriber filters out irrelevant events internally
      Caboose::Subscriber.subscribe!
    end

    initializer "caboose.error_subscriber" do
      # Subscribe to Rails error reporter for exception tracking
      Caboose::ErrorSubscriber.subscribe!
    end

    initializer "caboose.net_http_subscriber" do
      # Subscribe to Net::HTTP requests for HTTP client tracking
      Caboose::NetHttpSubscriber.subscribe!
    end

    initializer "caboose.active_job" do
      ActiveSupport.on_load(:active_job) do
        include Caboose::ActiveJobExtension
      end
    end

    initializer "caboose.resque" do
      # Wrap Resque::Job#perform to track job execution
      if defined?(Resque::Job)
        Resque::Job.prepend(Caboose::ResqueJobPatch)
      end
    end

    initializer "caboose.routes", before: :add_routing_paths do |app|
      if Rails.env.development? || Rails.env.test?
        app.routes.prepend do
          mount Caboose::Engine => "/caboose"
        end
      end
    end
  end
end
