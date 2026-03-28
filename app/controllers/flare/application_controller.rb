# frozen_string_literal: true

module Flare
  class ApplicationController < ActionController::Base
    protect_from_forgery with: :exception

    layout "flare/application"

    before_action :require_storage

    helper_method :show_redis_tab?

    private

    def require_storage
      return if Flare.storage

      render plain: "Flare dashboard requires the sqlite3 gem. Add `gem 'sqlite3'` to your Gemfile.", status: :service_unavailable
    end

    # Only show the Redis tab if:
    # 1. The Redis client library is loaded
    # 2. There are Redis spans in the database
    def show_redis_tab?
      return false unless defined?(::Redis)

      Flare.storage.count_spans_by_category("redis") > 0
    end
  end
end
