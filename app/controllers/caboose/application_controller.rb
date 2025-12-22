# frozen_string_literal: true

module Caboose
  class ApplicationController < ActionController::Base
    protect_from_forgery with: :exception

    layout "caboose/application"
  end
end
