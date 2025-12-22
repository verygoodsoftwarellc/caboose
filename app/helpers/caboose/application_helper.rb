# frozen_string_literal: true

module Caboose
  module ApplicationHelper
    def format_duration(ms)
      return "-" if ms.nil?

      if ms >= 1000
        "#{(ms / 1000.0).round(1)}s"
      else
        "#{ms.round(1)}ms"
      end
    end

    def format_content(data, indent = 0)
      return "" if data.nil?

      lines = []
      prefix = "  " * indent

      case data
      when Hash
        data.each do |key, value|
          if value.is_a?(Hash) || value.is_a?(Array)
            lines << "#{prefix}#{key}:"
            lines << format_content(value, indent + 1)
          else
            formatted_value = format_value(value)
            if formatted_value.include?("\n")
              lines << "#{prefix}#{key}:"
              formatted_value.each_line do |line|
                lines << "#{prefix}  #{line.rstrip}"
              end
            else
              lines << "#{prefix}#{key}: #{formatted_value}"
            end
          end
        end
      when Array
        data.each do |item|
          if item.is_a?(Hash) || item.is_a?(Array)
            lines << "#{prefix}-"
            lines << format_content(item, indent + 1)
          else
            lines << "#{prefix}- #{format_value(item)}"
          end
        end
      else
        lines << "#{prefix}#{format_value(data)}"
      end

      lines.join("\n")
    end

    private

    def format_value(value)
      case value
      when nil
        "null"
      when true, false
        value.to_s
      when Numeric
        value.to_s
      else
        value.to_s
      end
    end
  end
end
