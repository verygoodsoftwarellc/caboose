# frozen_string_literal: true

module Caboose
  class CluesController < ApplicationController
    helper_method :current_section, :page_title, :clue_summary, :clue_description

    PER_PAGE = 50

    def index
      @offset = params[:offset].to_i
      filter_params = {
        type: params[:type].presence,
        search: params[:search].presence
      }
      # Fetch one extra to know if there's a next page
      clues = Caboose.storage.list_clues(**filter_params, limit: PER_PAGE + 1, offset: @offset)
      @total_count = Caboose.storage.count_clues(**filter_params)
      @has_next = clues.size > PER_PAGE
      @clues = clues.first(PER_PAGE)
      @has_prev = @offset > 0
    end

    def show
      @clue = Caboose.storage.find_clue(params[:id])

      if @clue.blank?
        redirect_to clues_path, alert: "Clue not found"
        return
      end

      @case = Caboose.storage.find_case(@clue[:case_uuid])
    end

    private

    def current_section
      # Use params[:type] for index, or infer from @clue for show
      clue_type = params[:type] || infer_clue_type
      case clue_type
      when "sql" then "queries"
      when "cache" then "cache"
      when "view" then "views"
      when "mail" then "mail"
      when "http" then "http"
      when "exception" then "exceptions"
      else "all"
      end
    end

    def infer_clue_type
      return nil unless @clue

      case @clue[:type]
      when /sql|active_record/ then "sql"
      when /cache/ then "cache"
      when /render|view/ then "view"
      when /mail/ then "mail"
      when /http|request/ then "http"
      when /exception/ then "exception"
      end
    end

    def page_title
      case current_section
      when "queries" then "Queries"
      when "cache" then "Cache"
      when "views" then "Views"
      when "mail" then "Mail"
      when "http" then "HTTP Requests"
      when "exceptions" then "Exceptions"
      else "All Clues"
      end
    end

    def clue_summary(clue)
      content = clue[:content] || {}

      case clue[:type]
      when /sql|active_record/
        content["name"] || clue[:type]
      when /cache/
        key = content["key"]
        key = key.is_a?(Array) ? key.join("/") : key.to_s
        key.presence || clue[:type]
      when /render|view/
        content["identifier"]&.to_s&.split("/")&.last(2)&.join("/") || clue[:type]
      when /mail/
        content["mailer"] || content["to"] || clue[:type]
      when /http/
        "#{content["method"]} #{content["url"]}"
      when /exception/
        "#{content["class"]}: #{content["message"]}"
      when /middleware/
        content["middleware"] || clue[:type]
      else
        content.values.first&.to_s || clue[:type]
      end
    end

    def clue_description(clue)
      content = clue[:content] || {}

      case clue[:type]
      when /sql|active_record/
        content["sql"]&.to_s || content["name"] || clue[:type]
      when /cache/
        content["store"].presence || clue[:type]
      when /render|view/
        content["layout"] || clue[:type]
      when /mail/
        content["mailer"] || content["to"] || clue[:type]
      when /http/
        "#{content["method"]} #{content["url"]}"
      when /exception/
        "#{content["class"]}: #{content["message"]}"
      when /middleware/
        clue[:type].split(".").first
      else
        content.values.first&.to_s || clue[:type]
      end
    end
  end
end
