# frozen_string_literal: true

Caboose::Engine.routes.draw do
  resources :cases, only: [:index, :show]
  resources :clues, only: [:index, :show]

  delete "clear", to: "cases#clear", as: :clear_data

  root to: "cases#index"
end
