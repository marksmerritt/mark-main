class WritingStatsController < ApplicationController
  before_action :require_notes_connection

  include ActionView::Helpers::NumberHelper

  def show
    threads = {}
    threads[:notes] = Thread.new { notes_client.notes(per_page: 1000) }
    threads[:stats] = Thread.new { notes_client.stats rescue {} }
    threads[:notebooks] = Thread.new { notes_client.notebooks rescue [] }

    notes_result = threads[:notes].value
    @notes = notes_result.is_a?(Hash) ? (notes_result["notes"] || []) : Array(notes_result)
    @notes = @notes.select { |n| n.is_a?(Hash) }
    @stats = threads[:stats].value || {}
    notebooks_result = threads[:notebooks].value
    @notebooks = notebooks_result.is_a?(Array) ? notebooks_result : (notebooks_result.is_a?(Hash) ? (notebooks_result["notebooks"] || []) : [])

    # Word counts per note
    @notes.each do |n|
      content = n["content"] || n["body"] || ""
      n["_word_count"] = content.split(/\s+/).reject(&:blank?).count
      n["_char_count"] = content.length
    end

    # Overall stats
    @total_notes = @notes.count
    @total_words = @notes.sum { |n| n["_word_count"] }
    @total_chars = @notes.sum { |n| n["_char_count"] }
    @avg_words = @total_notes > 0 ? (@total_words / @total_notes).round(0) : 0
    @longest_note = @notes.max_by { |n| n["_word_count"] }
    @shortest_note = @notes.select { |n| n["_word_count"] > 0 }.min_by { |n| n["_word_count"] }

    # Daily writing volume
    @daily_words = {}
    @notes.each do |n|
      date = (n["created_at"] || n["updated_at"])&.to_s&.slice(0, 10)
      next unless date
      @daily_words[date] ||= 0
      @daily_words[date] += n["_word_count"]
    end

    # Weekly writing trend
    @weekly_notes = {}
    @notes.each do |n|
      date = Date.parse(n["created_at"] || n["updated_at"] || "") rescue nil
      next unless date
      week = date.beginning_of_week.to_s
      @weekly_notes[week] ||= { count: 0, words: 0 }
      @weekly_notes[week][:count] += 1
      @weekly_notes[week][:words] += n["_word_count"]
    end
    @weekly_notes = @weekly_notes.sort_by { |k, _| k }.last(12).to_h

    # Notes by notebook
    @by_notebook = {}
    @notes.each do |n|
      nb = n.dig("notebook", "name") || "No Notebook"
      @by_notebook[nb] ||= { count: 0, words: 0 }
      @by_notebook[nb][:count] += 1
      @by_notebook[nb][:words] += n["_word_count"]
    end
    @by_notebook = @by_notebook.sort_by { |_, v| -v[:words] }.to_h

    # Writing time distribution
    @hour_distribution = Array.new(24, 0)
    @notes.each do |n|
      ts = n["created_at"]
      next unless ts.to_s.include?("T") || ts.to_s.include?(":")
      hour = Time.parse(ts).hour rescue nil
      @hour_distribution[hour] += 1 if hour
    end

    # Day of week distribution
    @dow_distribution = Array.new(7, 0)
    @notes.each do |n|
      date = Date.parse(n["created_at"] || "") rescue nil
      next unless date
      @dow_distribution[date.wday] += 1
    end

    # Favorites and pins
    @favorites_count = @notes.count { |n| n["favorited"] || n["is_favorite"] }
    @pinned_count = @notes.count { |n| n["pinned"] || n["is_pinned"] }

    # Tags usage
    @tag_usage = {}
    @notes.each do |n|
      tags = n["tags"] || []
      tags.each do |tag|
        name = tag.is_a?(Hash) ? tag["name"] : tag.to_s
        @tag_usage[name] ||= 0
        @tag_usage[name] += 1
      end
    end
    @tag_usage = @tag_usage.sort_by { |_, v| -v }.first(15).to_h

    # Writing streak
    sorted_dates = @notes.filter_map { |n| Date.parse(n["created_at"] || "") rescue nil }.uniq.sort
    @writing_streak = 0
    if sorted_dates.any?
      current = Date.current
      while sorted_dates.include?(current)
        @writing_streak += 1
        current -= 1
      end
    end
  end
end
