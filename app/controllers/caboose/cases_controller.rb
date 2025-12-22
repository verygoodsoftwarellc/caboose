# frozen_string_literal: true

module Caboose
  class CasesController < ApplicationController
    helper_method :current_section, :page_title, :current_origin

    PER_PAGE = 50

    def index
      @offset = params[:offset].to_i
      filter_params = {
        type: params[:type].presence,
        status: params[:status].presence,
        method: params[:method].presence,
        name: params[:name].presence,
        origin: current_origin
      }
      # Fetch one extra to know if there's a next page
      cases = Caboose.storage.list_cases(**filter_params, limit: PER_PAGE + 1, offset: @offset)
      @total_count = Caboose.storage.count_cases(**filter_params)
      @has_next = cases.size > PER_PAGE
      @cases = cases.first(PER_PAGE)
      @has_prev = @offset > 0
    end

    def show
      @case = Caboose.storage.find_case(params[:id])

      if @case.blank?
        redirect_to cases_path, alert: "Case not found"
        return
      end

      @clues = Caboose.storage.clues_for_case(params[:id])

      # Load parent case if this was triggered by another case
      if @case[:parent_case_uuid]
        @parent_case = Caboose.storage.find_case(@case[:parent_case_uuid])
      end
    end

    def clear
      Caboose.storage.clear_all
      redirect_to root_path
    end

    private

    def current_section
      # Check params first (for index), then @case (for show)
      case_type = params[:type] || @case&.dig(:type)
      return "requests" if case_type == "request"
      return "jobs" if case_type == "job"
      "all"
    end

    def page_title
      case current_section
      when "requests" then "Requests"
      when "jobs" then "Jobs"
      else "All Cases"
      end
    end

    def current_origin
      # If origin was explicitly set (even to empty for "All"), use that
      if params.key?(:origin)
        return params[:origin].presence  # nil for "All Origins", "app" or "rails" otherwise
      end

      # Default to "app" for requests and all views to hide Rails framework noise
      if params[:type] == "request" || params[:type].blank?
        "app"
      end
    end
  end
end
