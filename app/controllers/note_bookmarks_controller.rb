class NoteBookmarksController < ApplicationController
  before_action :require_notes_connection

  def show
    threads = {}
    threads[:notes] = Thread.new { notes_client.notes(per_page: 1000) }
    threads[:notebooks] = Thread.new { notes_client.notebooks rescue [] }

    notes_result = threads[:notes].value
    all_notes = notes_result.is_a?(Hash) ? (notes_result["notes"] || []) : Array(notes_result)
    all_notes = all_notes.select { |n| n.is_a?(Hash) }

    notebooks_result = threads[:notebooks].value
    @notebooks = notebooks_result.is_a?(Array) ? notebooks_result : (notebooks_result.is_a?(Hash) ? (notebooks_result["notebooks"] || []) : [])

    # Build notebook lookup
    notebook_lookup = {}
    @notebooks.each { |nb| notebook_lookup[nb["id"].to_s] = nb["name"] || "Untitled Notebook" }

    # Pinned notes
    @pinned_notes = all_notes.select { |n| n["pinned"] || n["is_pinned"] }

    # Favorite notes
    @favorite_notes = all_notes.select { |n| n["favorited"] || n["is_favorited"] || n["favorite"] }

    # Recently updated: last 10 by update date
    @recently_updated = all_notes
      .select { |n| n["updated_at"].present? }
      .sort_by { |n| n["updated_at"].to_s }
      .reverse
      .first(10)

    # Recently created: last 10 by creation date
    @recently_created = all_notes
      .select { |n| n["created_at"].present? }
      .sort_by { |n| n["created_at"].to_s }
      .reverse
      .first(10)

    # Most substantial: top 10 by word count (reference materials)
    @most_substantial = all_notes
      .sort_by { |n| -(n["word_count"].to_i) }
      .first(10)

    # Quick notes: shortest notes under 50 words
    @quick_notes = all_notes
      .select { |n| n["word_count"].to_i > 0 && n["word_count"].to_i < 50 }
      .sort_by { |n| n["word_count"].to_i }
      .first(20)

    # By notebook: organized bookmark shelf
    @by_notebook = {}
    all_notes.each do |note|
      nb_name = notebook_lookup[note["notebook_id"].to_s] || "Uncategorized"
      @by_notebook[nb_name] ||= []
      @by_notebook[nb_name] << note
    end
    @by_notebook = @by_notebook.sort_by { |name, notes| -notes.length }.to_h

    # Tag cloud: all tags with counts
    @tag_cloud = {}
    all_notes.each do |note|
      tags = note["tags"] || []
      tags.each do |tag|
        name = tag.is_a?(Hash) ? (tag["name"] || "unknown") : tag.to_s
        @tag_cloud[name] = (@tag_cloud[name] || 0) + 1
      end
    end
    @tag_cloud = @tag_cloud.sort_by { |_, count| -count }.to_h

    # Activity heatmap: notes updated by month for last 12 months
    @activity_heatmap = {}
    12.times do |i|
      month_date = Date.current - i.months
      key = month_date.strftime("%Y-%m")
      @activity_heatmap[key] = 0
    end
    all_notes.each do |note|
      date_str = (note["updated_at"] || note["created_at"]).to_s.slice(0, 7)
      next unless date_str.present?
      @activity_heatmap[date_str] = (@activity_heatmap[date_str] || 0) + 1 if @activity_heatmap.key?(date_str)
    end
    @activity_heatmap = @activity_heatmap.sort_by { |k, _| k }.to_h

    # Compute stats
    @total_pinned = @pinned_notes.count
    @total_favorites = @favorite_notes.count
    @total_notebooks = @notebooks.count
    @total_quick = @quick_notes.count
    @avg_per_notebook = @total_notebooks > 0 ? (all_notes.count.to_f / @total_notebooks).round(1) : 0
    @total_notes = all_notes.count
  end
end
