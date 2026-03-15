class NoteMaintenanceController < ApplicationController
  before_action :require_notes_connection

  def show
    threads = {}
    threads[:notes] = Thread.new { notes_client.notes(per_page: 1000) }
    threads[:notebooks] = Thread.new { notes_client.notebooks rescue [] }

    notes_result = threads[:notes].value
    all_notes = notes_result.is_a?(Hash) ? (notes_result["notes"] || []) : Array(notes_result)
    @notes = all_notes.select { |n| n.is_a?(Hash) }

    notebooks_result = threads[:notebooks].value
    @notebooks = notebooks_result.is_a?(Array) ? notebooks_result : (notebooks_result.is_a?(Hash) ? (notebooks_result["notebooks"] || []) : [])

    # Compute word counts defensively
    @notes.each do |n|
      content = (n["content"] || n["body"] || "").to_s
      words = content.split(/\s+/).reject(&:blank?)
      n["_word_count"] = words.count
      n["_char_count"] = content.length
    end

    analyze_library
  end

  private

  def analyze_library
    now = Time.current
    notebook_ids = Set.new(@notebooks.map { |nb| nb["id"].to_s })

    # -- Stale notes: not updated in 90+ days --
    @stale_notes = @notes.select do |n|
      updated = n["updated_at"] || n["created_at"]
      next false unless updated
      days = ((now - Time.parse(updated.to_s)) / 1.day).round rescue nil
      next false unless days
      n["_days_stale"] = days
      days >= 90
    end.sort_by { |n| -(n["_days_stale"] || 0) }

    # -- Empty / near-empty notes: fewer than 10 words --
    @empty_notes = @notes.select { |n| n["_word_count"].to_i < 10 }
      .sort_by { |n| n["_word_count"].to_i }

    # -- Duplicate detection: titles sharing 80%+ words --
    @duplicate_pairs = detect_duplicates

    # -- Untagged notes --
    @untagged_notes = @notes.select { |n| (n["tags"] || []).empty? }

    # -- Uncategorized notes: not in any notebook --
    @uncategorized_notes = @notes.select do |n|
      nb_id = n["notebook_id"].to_s
      nb_name = n.dig("notebook", "name").to_s
      nb_id.blank? && nb_name.blank?
    end

    # -- Large notes: over 2000 words --
    @large_notes = @notes.select { |n| n["_word_count"].to_i > 2000 }
      .sort_by { |n| -n["_word_count"].to_i }

    # -- Untitled notes --
    @untitled_notes = @notes.select do |n|
      title = n["title"].to_s.strip
      title.blank? || title.downcase == "untitled"
    end

    # -- Storage stats --
    @total_chars = @notes.sum { |n| n["_char_count"].to_i }
    @total_words = @notes.sum { |n| n["_word_count"].to_i }
    @estimated_storage_kb = (@total_chars / 1024.0).round(1)
    @estimated_storage_mb = (@total_chars / (1024.0 * 1024.0)).round(2)

    # -- Library health score (0-100) --
    @health_score = compute_health_score

    # -- Health grade --
    @health_grade = case @health_score
                    when 90..100 then "A"
                    when 80..89  then "B"
                    when 70..79  then "C"
                    when 60..69  then "D"
                    else              "F"
                    end

    # -- Cleanup suggestions --
    @cleanup_suggestions = build_cleanup_suggestions
  end

  def detect_duplicates
    pairs = []
    checked = Set.new
    @notes.each do |note_a|
      title_a = note_a["title"].to_s.strip
      next if title_a.blank? || title_a.downcase == "untitled"
      words_a = title_a.downcase.gsub(/[^a-z0-9\s]/, "").split(/\s+/).reject { |w| w.length < 2 }
      next if words_a.empty?

      @notes.each do |note_b|
        next if note_a["id"] == note_b["id"]
        pair_key = [note_a["id"], note_b["id"]].sort
        next if checked.include?(pair_key)
        checked.add(pair_key)

        title_b = note_b["title"].to_s.strip
        next if title_b.blank? || title_b.downcase == "untitled"
        words_b = title_b.downcase.gsub(/[^a-z0-9\s]/, "").split(/\s+/).reject { |w| w.length < 2 }
        next if words_b.empty?

        # Check word overlap: 80%+ of the smaller set shared
        shared = (words_a & words_b).count
        min_len = [words_a.count, words_b.count].min
        next if min_len == 0
        overlap = shared.to_f / min_len

        if overlap >= 0.8
          pairs << { note_a: note_a, note_b: note_b, overlap: (overlap * 100).round(0) }
        end
      end
    end
    pairs.sort_by { |p| -p[:overlap] }.first(20)
  end

  def compute_health_score
    return 100 if @notes.empty?

    total = @notes.count.to_f
    # Percentage of notes that are well-organized
    tagged_pct = (@notes.count { |n| (n["tags"] || []).any? }) / total
    categorized_pct = (@notes.count { |n| n["notebook_id"].to_s.present? || n.dig("notebook", "name").to_s.present? }) / total
    reasonable_length_pct = (@notes.count { |n| wc = n["_word_count"].to_i; wc >= 10 && wc <= 2000 }) / total
    fresh_pct = (@notes.count { |n|
      updated = n["updated_at"] || n["created_at"]
      next false unless updated
      days = ((Time.current - Time.parse(updated.to_s)) / 1.day) rescue nil
      days && days < 90
    }) / total
    titled_pct = (@notes.count { |n| t = n["title"].to_s.strip; t.present? && t.downcase != "untitled" }) / total
    no_dupes_pct = 1.0 - (@duplicate_pairs.count * 2.0 / [total, 1].max).clamp(0, 1)

    # Weighted average
    score = (
      tagged_pct * 20 +
      categorized_pct * 20 +
      reasonable_length_pct * 15 +
      fresh_pct * 20 +
      titled_pct * 15 +
      no_dupes_pct * 10
    ).round(0)

    score.clamp(0, 100)
  end

  def build_cleanup_suggestions
    suggestions = []

    if @untitled_notes.any?
      suggestions << {
        icon: "title",
        label: "Add titles to untitled notes",
        count: @untitled_notes.count,
        priority: 1,
        color: "#e53935",
        link_text: "Fix titles",
        anchor: "untitled"
      }
    end

    if @empty_notes.any?
      suggestions << {
        icon: "edit_note",
        label: "Flesh out empty or near-empty notes",
        count: @empty_notes.count,
        priority: 2,
        color: "#f57c00",
        link_text: "Review empty",
        anchor: "empty"
      }
    end

    if @duplicate_pairs.any?
      suggestions << {
        icon: "file_copy",
        label: "Review potential duplicate notes",
        count: @duplicate_pairs.count,
        priority: 3,
        color: "#e91e63",
        link_text: "Review duplicates",
        anchor: "duplicates"
      }
    end

    if @untagged_notes.any?
      suggestions << {
        icon: "sell",
        label: "Tag untagged notes for better organization",
        count: @untagged_notes.count,
        priority: 4,
        color: "#7b1fa2",
        link_text: "Tag notes",
        anchor: "untagged"
      }
    end

    if @uncategorized_notes.any?
      suggestions << {
        icon: "folder_open",
        label: "Move uncategorized notes into notebooks",
        count: @uncategorized_notes.count,
        priority: 5,
        color: "#1565c0",
        link_text: "Categorize",
        anchor: "uncategorized"
      }
    end

    if @stale_notes.any?
      suggestions << {
        icon: "update",
        label: "Review and refresh stale notes",
        count: @stale_notes.count,
        priority: 6,
        color: "#607d8b",
        link_text: "Review stale",
        anchor: "stale"
      }
    end

    if @large_notes.any?
      suggestions << {
        icon: "call_split",
        label: "Consider splitting large notes",
        count: @large_notes.count,
        priority: 7,
        color: "#00838f",
        link_text: "Review large",
        anchor: "large"
      }
    end

    suggestions.sort_by { |s| s[:priority] }
  end
end
