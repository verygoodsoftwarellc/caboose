# frozen_string_literal: true

Caboose::Engine.routes.draw do
  resources :requests, only: [:index, :show]

  delete "clear", to: "requests#clear", as: :clear_data

  root to: "requests#index"
end
