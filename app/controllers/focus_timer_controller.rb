class FocusTimerController < ApplicationController
  before_action :require_notes_connection

  def show
    notes_result = notes_client.notes(per_page: 100) rescue []
    @notes = notes_result.is_a?(Hash) ? (notes_result["notes"] || []) : Array(notes_result)
    @notes = @notes.select { |n| n.is_a?(Hash) }

    notebooks_result = notes_client.notebooks rescue []
    @notebooks = notebooks_result.is_a?(Array) ? notebooks_result : (notebooks_result.is_a?(Hash) ? (notebooks_result["notebooks"] || []) : [])

    # Enrich notes with word counts and parsed dates
    @notes.each do |n|
      content = n["content"] || n["body"] || ""
      n["_word_count"] = content.split(/\s+/).reject(&:blank?).count
      n["_created_date"] = Date.parse(n["created_at"] || n["updated_at"] || "") rescue nil
    end

    today = Date.current
    week_start = today.beginning_of_week

    # Recent notes (last 7 days) with word counts
    @recent_notes = @notes
      .select { |n| n["_created_date"] && (today - n["_created_date"]).to_i <= 7 }
      .sort_by { |n| n["created_at"] || "" }
      .reverse

    # Total words this week
    week_notes = @notes.select { |n| n["_created_date"] && n["_created_date"] >= week_start }
    @total_words_this_week = week_notes.sum { |n| n["_word_count"] }

    # Average words per session (notes created same day grouped)
    daily_word_counts = {}
    @notes.each do |n|
      date = n["_created_date"]
      next unless date
      daily_word_counts[date] ||= 0
      daily_word_counts[date] += n["_word_count"]
    end
    @avg_words_per_session = daily_word_counts.any? ? (daily_word_counts.values.sum / daily_word_counts.count.to_f).round(0) : 0

    # Best writing day this week
    week_daily = {}
    week_notes.each do |n|
      date = n["_created_date"]
      next unless date
      week_daily[date] ||= 0
      week_daily[date] += n["_word_count"]
    end
    best_day_entry = week_daily.max_by { |_, words| words }
    @best_day = if best_day_entry
      { date: best_day_entry[0], words: best_day_entry[1] }
    else
      nil
    end

    # Writing streak
    sorted_dates = @notes.filter_map { |n| n["_created_date"] }.uniq.sort
    @writing_streak = 0
    if sorted_dates.any?
      current = today
      while sorted_dates.include?(current)
        @writing_streak += 1
        current -= 1
      end
    end

    # Sessions today
    @sessions_today = @notes.count { |n| n["_created_date"] == today }

    # Timer presets
    @presets = [
      { name: "Classic Pomodoro", work: 25, break_time: 5, icon: "timer", color: "#e53935" },
      { name: "Deep Focus", work: 50, break_time: 10, icon: "psychology", color: "#283593" },
      { name: "Quick Sprint", work: 15, break_time: 3, icon: "bolt", color: "#f57c00" },
      { name: "Marathon", work: 90, break_time: 15, icon: "self_improvement", color: "#2e7d32" }
    ]

    # Suggest which notebook/topic to write about based on neglected notebooks
    notes_by_notebook = {}
    @notes.each do |n|
      nb_name = n.dig("notebook", "name") || "No Notebook"
      nb_id = n.dig("notebook", "id") || n["notebook_id"]
      notes_by_notebook[nb_name] ||= { id: nb_id, notes: [], last_date: nil }
      notes_by_notebook[nb_name][:notes] << n
      d = n["_created_date"]
      if d && (notes_by_notebook[nb_name][:last_date].nil? || d > notes_by_notebook[nb_name][:last_date])
        notes_by_notebook[nb_name][:last_date] = d
      end
    end

    @neglected_notebooks = notes_by_notebook
      .reject { |name, _| name == "No Notebook" }
      .select { |_, data| data[:last_date] }
      .sort_by { |_, data| data[:last_date] }
      .first(5)
      .to_h

    @suggested_topic = if @neglected_notebooks.any?
      name, data = @neglected_notebooks.first
      days_ago = (today - data[:last_date]).to_i
      { notebook: name, days_ago: days_ago, note_count: data[:notes].count }
    else
      nil
    end

    # Last 5 notes for recent activity
    @last_five = @notes
      .sort_by { |n| n["created_at"] || "" }
      .reverse
      .first(5)
  end
end
