class ReadingStatsController < ApplicationController
  before_action :require_notes_connection

  include ActionView::Helpers::NumberHelper

  def show
    threads = {}
    threads[:notes] = Thread.new { notes_client.notes(per_page: 1000) }
    threads[:notebooks] = Thread.new { notes_client.notebooks rescue [] }

    notes_result = threads[:notes].value
    @notes = notes_result.is_a?(Hash) ? (notes_result["notes"] || []) : Array(notes_result)
    @notes = @notes.select { |n| n.is_a?(Hash) }
    notebooks_result = threads[:notebooks].value
    @notebooks = notebooks_result.is_a?(Array) ? notebooks_result : (notebooks_result.is_a?(Hash) ? (notebooks_result["notebooks"] || []) : [])

    # Word counts and reading time per note (200 WPM average)
    @notes.each do |n|
      content = n["content"] || n["body"] || ""
      n["_word_count"] = content.split(/\s+/).reject(&:blank?).count
      n["_reading_minutes"] = (n["_word_count"] / 200.0).round(1)
      n["_created_date"] = Date.parse(n["created_at"] || n["updated_at"] || "") rescue nil
      n["_updated_date"] = Date.parse(n["updated_at"] || n["created_at"] || "") rescue nil
    end

    # --- Overall stats ---
    @total_notes = @notes.count
    @total_words = @notes.sum { |n| n["_word_count"] }
    @total_reading_minutes = @notes.sum { |n| n["_reading_minutes"] }
    @total_reading_hours = (@total_reading_minutes / 60.0).round(1)
    @avg_words = @total_notes > 0 ? (@total_words.to_f / @total_notes).round(0) : 0

    # Median word count
    sorted_wc = @notes.map { |n| n["_word_count"] }.sort
    @median_words = if sorted_wc.empty?
      0
    elsif sorted_wc.length.odd?
      sorted_wc[sorted_wc.length / 2]
    else
      mid = sorted_wc.length / 2
      ((sorted_wc[mid - 1] + sorted_wc[mid]) / 2.0).round(0)
    end

    # Library size in book equivalents (avg book ~70,000 words)
    @book_equivalents = (@total_words / 70000.0).round(2)

    # Words per day average
    dated_notes = @notes.select { |n| n["_created_date"] }
    if dated_notes.any?
      first_date = dated_notes.map { |n| n["_created_date"] }.compact.min
      days_since = [(Date.current - first_date).to_i, 1].max
      @words_per_day = (@total_words.to_f / days_since).round(0)
      @days_since_first = days_since
    else
      @words_per_day = 0
      @days_since_first = 0
    end

    # --- Reading time distribution buckets ---
    @time_buckets = { "< 1 min" => 0, "1-3 min" => 0, "3-5 min" => 0, "5-10 min" => 0, "10+ min" => 0 }
    @notes.each do |n|
      mins = n["_reading_minutes"]
      if mins < 1
        @time_buckets["< 1 min"] += 1
      elsif mins < 3
        @time_buckets["1-3 min"] += 1
      elsif mins < 5
        @time_buckets["3-5 min"] += 1
      elsif mins < 10
        @time_buckets["5-10 min"] += 1
      else
        @time_buckets["10+ min"] += 1
      end
    end

    # --- Reading time by notebook ---
    @by_notebook = {}
    @notes.each do |n|
      nb = n.dig("notebook", "name") || "No Notebook"
      @by_notebook[nb] ||= { count: 0, words: 0, reading_minutes: 0.0 }
      @by_notebook[nb][:count] += 1
      @by_notebook[nb][:words] += n["_word_count"]
      @by_notebook[nb][:reading_minutes] += n["_reading_minutes"]
    end
    @by_notebook = @by_notebook.sort_by { |_, v| -v[:reading_minutes] }.to_h

    # --- Longest reads (top 5) ---
    @longest_reads = @notes.sort_by { |n| -n["_word_count"] }.first(5)

    # --- Shortest notes (bottom 5 with content) ---
    @shortest_notes = @notes.select { |n| n["_word_count"] > 0 }.sort_by { |n| n["_word_count"] }.first(5)

    # --- Growth over time (cumulative words and notes by month) ---
    @growth_data = {}
    @notes.select { |n| n["_created_date"] }.sort_by { |n| n["_created_date"] }.each do |n|
      month_key = n["_created_date"].strftime("%Y-%m")
      @growth_data[month_key] ||= { words: 0, notes: 0 }
      @growth_data[month_key][:words] += n["_word_count"]
      @growth_data[month_key][:notes] += 1
    end
    # Make cumulative
    @cumulative_growth = {}
    running_words = 0
    running_notes = 0
    @growth_data.sort_by { |k, _| k }.each do |month, data|
      running_words += data[:words]
      running_notes += data[:notes]
      @cumulative_growth[month] = { words: running_words, notes: running_notes }
    end

    # --- Content freshness ---
    today = Date.current
    @freshness = { fresh: 0, aging: 0, stale: 0 }
    @notes.each do |n|
      updated = n["_updated_date"]
      if updated && (today - updated).to_i <= 30
        @freshness[:fresh] += 1
      elsif updated && (today - updated).to_i <= 90
        @freshness[:aging] += 1
      else
        @freshness[:stale] += 1
      end
    end
    @freshness_pct = {}
    total_for_pct = [@total_notes, 1].max
    @freshness_pct[:fresh] = (@freshness[:fresh].to_f / total_for_pct * 100).round(1)
    @freshness_pct[:aging] = (@freshness[:aging].to_f / total_for_pct * 100).round(1)
    @freshness_pct[:stale] = (@freshness[:stale].to_f / total_for_pct * 100).round(1)
  end
end
