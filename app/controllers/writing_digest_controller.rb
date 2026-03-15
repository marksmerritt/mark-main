class WritingDigestController < ApplicationController
  before_action :require_notes_connection

  include ActionView::Helpers::NumberHelper

  def show
    notes_result = notes_client.notes(per_page: 1000) rescue []
    @notes = notes_result.is_a?(Hash) ? (notes_result["notes"] || []) : Array(notes_result)
    @notes = @notes.select { |n| n.is_a?(Hash) }

    # Word counts per note
    @notes.each do |n|
      content = n["content"] || n["body"] || ""
      n["_word_count"] = content.split(/\s+/).reject(&:blank?).count
    end

    today = Date.current
    beginning_of_week = today.beginning_of_week(:monday)
    last_week_start = beginning_of_week - 7
    last_week_end = beginning_of_week - 1

    # Parse dates for each note
    @notes.each do |n|
      n["_created_date"] = Date.parse(n["created_at"] || n["updated_at"] || "") rescue nil
      n["_updated_date"] = Date.parse(n["updated_at"] || n["created_at"] || "") rescue nil
    end

    # Today's writing
    @today_notes = @notes.select { |n| n["_created_date"] == today || n["_updated_date"] == today }
    @today_words = @today_notes.sum { |n| n["_word_count"] }

    # This week's writing
    @week_notes = @notes.select { |n| d = n["_created_date"]; d && d >= beginning_of_week && d <= today }
    @week_words = @week_notes.sum { |n| n["_word_count"] }

    # Daily breakdown for this week (Mon-Sun)
    @daily_breakdown = {}
    (beginning_of_week..today).each { |d| @daily_breakdown[d] = 0 }
    @week_notes.each do |n|
      d = n["_created_date"]
      @daily_breakdown[d] = (@daily_breakdown[d] || 0) + n["_word_count"] if d
    end

    # Last week's writing for comparison
    last_week_notes = @notes.select { |n| d = n["_created_date"]; d && d >= last_week_start && d <= last_week_end }
    @last_week_words = last_week_notes.sum { |n| n["_word_count"] }
    @last_week_count = last_week_notes.count
    @last_week_avg = @last_week_count > 0 ? (@last_week_words.to_f / @last_week_count).round(0) : 0

    @this_week_avg = @week_notes.count > 0 ? (@week_words.to_f / @week_notes.count).round(0) : 0

    # Word delta
    @word_delta = @week_words - @last_week_words
    @note_delta = @week_notes.count - @last_week_count

    # Daily word goal
    @daily_goal = 500
    @goal_progress = @today_words > 0 ? [(@today_words.to_f / @daily_goal * 100).round(1), 100].min : 0

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

    # Productivity score (0-100)
    # Based on: consistency (streak), volume (words this week), variety (notebooks)
    streak_score = [@writing_streak * 10, 30].min
    volume_score = [@week_words.to_f / (@daily_goal * 7) * 40, 40].min.round(0)
    notebooks_this_week = @week_notes.map { |n| n.dig("notebook", "name") || "default" }.uniq.count
    variety_score = [notebooks_this_week * 10, 30].min
    @productivity_score = (streak_score + volume_score + variety_score).round(0)

    # Recent activity feed (last 10 notes)
    @recent_notes = @notes
      .select { |n| n["_created_date"] }
      .sort_by { |n| n["created_at"] || "" }
      .reverse
      .first(10)

    # Most active notebook this week
    nb_counts = {}
    @week_notes.each do |n|
      nb = n.dig("notebook", "name") || "No Notebook"
      nb_counts[nb] ||= { count: 0, words: 0 }
      nb_counts[nb][:count] += 1
      nb_counts[nb][:words] += n["_word_count"]
    end
    @most_active_notebook = nb_counts.max_by { |_, v| v[:words] }&.first || "None"
    @most_active_notebook_data = nb_counts[@most_active_notebook] || { count: 0, words: 0 }

    # Word count distribution
    @distribution = { short: 0, medium: 0, long: 0, epic: 0 }
    @notes.each do |n|
      wc = n["_word_count"]
      if wc < 100
        @distribution[:short] += 1
      elsif wc < 500
        @distribution[:medium] += 1
      elsif wc < 1000
        @distribution[:long] += 1
      else
        @distribution[:epic] += 1
      end
    end

    # Writing velocity (words per hour based on creation timestamps)
    timestamps = @notes.filter_map { |n| Time.parse(n["created_at"]) rescue nil }.sort
    if timestamps.length >= 2
      total_hours = (timestamps.last - timestamps.first) / 3600.0
      total_words = @notes.sum { |n| n["_word_count"] }
      @velocity = total_hours > 0 ? (total_words / total_hours).round(1) : 0
    else
      @velocity = 0
    end
  end
end
