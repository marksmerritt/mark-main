class NoteExportCenterController < ApplicationController
  before_action :require_notes_connection

  include ActionView::Helpers::NumberHelper

  helper_method :format_bytes

  def show
    threads = {}
    threads[:notes] = Thread.new { notes_client.notes(per_page: 1000) }
    threads[:notebooks] = Thread.new { notes_client.notebooks rescue [] }

    notes_result = threads[:notes].value
    all_notes = notes_result.is_a?(Hash) ? (notes_result["notes"] || []) : Array(notes_result)
    @notes = all_notes.select { |n| n.is_a?(Hash) }

    notebooks_result = threads[:notebooks].value
    @notebooks = notebooks_result.is_a?(Array) ? notebooks_result : (notebooks_result.is_a?(Hash) ? (notebooks_result["notebooks"] || []) : [])

    # Word/char counts per note
    @notes.each do |n|
      content = (n["content"] || n["body"] || "").to_s
      words = content.split(/\s+/).reject(&:blank?)
      n["_word_count"] = words.count
      n["_char_count"] = content.length
    end

    compute_export_stats
  end

  private

  def compute_export_stats
    # -- Total content --
    @total_notes = @notes.count
    @total_words = @notes.sum { |n| n["_word_count"].to_i }
    @total_chars = @notes.sum { |n| n["_char_count"].to_i }

    # -- By notebook --
    @by_notebook = {}
    @notes.each do |n|
      nb_name = n.dig("notebook", "name") || "No Notebook"
      nb_id = n["notebook_id"].to_s
      @by_notebook[nb_name] ||= { count: 0, words: 0, chars: 0, notebook_id: nb_id }
      @by_notebook[nb_name][:count] += 1
      @by_notebook[nb_name][:words] += n["_word_count"].to_i
      @by_notebook[nb_name][:chars] += n["_char_count"].to_i
    end
    @by_notebook = @by_notebook.sort_by { |_, v| -v[:words] }.to_h

    # -- Export size estimates by format --
    # Markdown: roughly 1.1x raw text (headers, formatting)
    # HTML: roughly 1.8x raw text (tags, structure, CSS)
    # JSON: roughly 2.2x raw text (keys, braces, metadata)
    # Plain text: roughly 1.0x raw text
    raw_bytes = @total_chars.to_f
    @format_estimates = {
      "Markdown (.md)" => { multiplier: 1.1, bytes: (raw_bytes * 1.1).round, icon: "description", color: "#1565c0" },
      "HTML (.html)" => { multiplier: 1.8, bytes: (raw_bytes * 1.8).round, icon: "code", color: "#e65100" },
      "JSON (.json)" => { multiplier: 2.2, bytes: (raw_bytes * 2.2).round, icon: "data_object", color: "#2e7d32" },
      "Plain Text (.txt)" => { multiplier: 1.0, bytes: raw_bytes.round, icon: "text_snippet", color: "#616161" }
    }

    # Estimated full backup size (JSON is the most comprehensive)
    @est_backup_bytes = (raw_bytes * 2.2).round
    @est_backup_kb = (@est_backup_bytes / 1024.0).round(1)
    @est_backup_mb = (@est_backup_bytes / (1024.0 * 1024.0)).round(2)

    # -- Content breakdown --
    @notes_with_images = @notes.count { |n|
      content = (n["content"] || n["body"] || "").to_s
      content.include?("![") || content.include?("<img") || content.match?(/\.(png|jpg|jpeg|gif|svg|webp)/i)
    }
    @text_only_notes = @total_notes - @notes_with_images

    # -- Last modified / oldest note --
    sorted_by_updated = @notes.sort_by { |n|
      (n["updated_at"] || n["created_at"] || "1970-01-01").to_s
    }
    @oldest_note = sorted_by_updated.first
    @newest_note = sorted_by_updated.last

    sorted_by_created = @notes.sort_by { |n|
      (n["created_at"] || "1970-01-01").to_s
    }
    @first_note_created = sorted_by_created.first

    # -- Export readiness: notes with potential issues --
    @empty_notes = @notes.select { |n| n["_word_count"].to_i < 10 }
    @untitled_notes = @notes.select { |n|
      title = n["title"].to_s.strip
      title.blank? || title.downcase == "untitled"
    }
    @large_notes = @notes.select { |n| n["_word_count"].to_i > 5000 }
      .sort_by { |n| -n["_word_count"].to_i }

    @issue_count = @empty_notes.count + @untitled_notes.count + @large_notes.count
    @export_ready = @issue_count == 0

    # -- Writing frequency and backup suggestion --
    @dates_written = @notes.filter_map { |n|
      Date.parse(n["created_at"] || "") rescue nil
    }.uniq.sort

    if @dates_written.length >= 2
      span_days = (@dates_written.last - @dates_written.first).to_i
      span_days = 1 if span_days == 0
      @notes_per_day = (@total_notes.to_f / span_days).round(2)
      @notes_per_week = (@notes_per_day * 7).round(1)

      @backup_suggestion = if @notes_per_week >= 10
                             { frequency: "Daily", icon: "schedule", color: "#e53935", reason: "You write #{@notes_per_week} notes/week -- daily backups recommended" }
                           elsif @notes_per_week >= 3
                             { frequency: "Every 2-3 days", icon: "date_range", color: "#f57c00", reason: "You write #{@notes_per_week} notes/week -- backup every few days" }
                           elsif @notes_per_week >= 1
                             { frequency: "Weekly", icon: "event", color: "#1565c0", reason: "You write #{@notes_per_week} notes/week -- weekly backups are sufficient" }
                           else
                             { frequency: "Monthly", icon: "calendar_month", color: "#4caf50", reason: "Low writing frequency -- monthly backups are fine" }
                           end
    else
      @notes_per_day = 0
      @notes_per_week = 0
      @backup_suggestion = { frequency: "Weekly", icon: "event", color: "#1565c0", reason: "Not enough data to determine frequency -- weekly is a safe default" }
    end

    # -- Library timeline --
    @first_note_date = @dates_written.first
    @latest_note_date = @dates_written.last
    @library_span_days = @first_note_date && @latest_note_date ? (@latest_note_date - @first_note_date).to_i : 0

    # Monthly note counts for timeline
    @monthly_notes = {}
    @dates_written.each do |d|
      month_key = d.strftime("%Y-%m")
      @monthly_notes[month_key] ||= 0
    end
    @notes.each do |n|
      date = Date.parse(n["created_at"] || "") rescue nil
      next unless date
      month_key = date.strftime("%Y-%m")
      @monthly_notes[month_key] ||= 0
      @monthly_notes[month_key] += 1
    end
    @monthly_notes = @monthly_notes.sort_by { |k, _| k }.to_h
  end

  def format_bytes(bytes)
    bytes = bytes.to_i
    if bytes >= 1024 * 1024
      "%.1f MB" % (bytes / (1024.0 * 1024.0))
    elsif bytes >= 1024
      "%.1f KB" % (bytes / 1024.0)
    else
      "#{bytes} B"
    end
  end
end
