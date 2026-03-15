class NotesController < ApplicationController
  before_action :require_notes_connection

  def index
    filter_params = params.permit(:notebook_id, :tag_id, :q, :favorited, :page).to_h.compact_blank
    threads = {}
    threads[:notes] = Thread.new { notes_client.notes(filter_params) }

    if params[:page].to_i <= 1
      threads[:stats] = Thread.new { notes_client.stats rescue {} }
      threads[:activity] = Thread.new { notes_client.activity_stats rescue [] }
      threads[:notebooks] = Thread.new { notes_client.notebooks }
      threads[:tags] = Thread.new { cached_notes_tags }
    end

    result = threads[:notes].value
    @notes = result["notes"] || result
    @meta = result["meta"] || {}

    if params[:page].to_i > 1
      render partial: "note_cards", layout: false
    else
      nb = threads[:notebooks].value
      @notebooks = nb.is_a?(Hash) ? (nb["notebooks"] || nb) : nb
      tg = threads[:tags].value
      @tags = tg.is_a?(Hash) ? (tg["tags"] || tg) : tg
      stats_result = threads[:stats].value
      @notes_stats = stats_result.is_a?(Hash) ? stats_result : {}
      activity_result = threads[:activity].value
      @activity = activity_result.is_a?(Array) ? activity_result : []
    end
  end

  def show
    threads = {}
    threads[:note] = Thread.new { notes_client.note(params[:id]) }
    threads[:backlinks] = Thread.new { notes_client.note_backlinks(params[:id]) rescue [] }
    threads[:similar] = Thread.new { notes_client.similar_notes(params[:id]) rescue [] }
    threads[:notebooks] = Thread.new { notes_client.notebooks rescue [] }

    @note = threads[:note].value
    backlinks_result = threads[:backlinks].value
    @backlinks = backlinks_result.is_a?(Array) ? backlinks_result : (backlinks_result.is_a?(Hash) ? (backlinks_result["notes"] || backlinks_result["backlinks"] || []) : [])
    similar_result = threads[:similar].value
    @similar_notes = similar_result.is_a?(Array) ? similar_result : (similar_result.is_a?(Hash) ? (similar_result["notes"] || similar_result["similar"] || []) : [])
    nb = threads[:notebooks].value
    @notebooks = nb.is_a?(Hash) ? (nb["notebooks"] || nb) : (nb.is_a?(Array) ? nb : [])
  end

  def new
    @note = {}
    @notebooks = notes_client.notebooks
    @notebooks = @notebooks["notebooks"] || @notebooks if @notebooks.is_a?(Hash)
    @tags = cached_notes_tags
    @tags = @tags["tags"] || @tags if @tags.is_a?(Hash)
  end

  def create
    result = notes_client.create_note(note_params.merge(tag_ids: params[:tag_ids]))
    if result["id"]
      redirect_to note_path(result["id"]), notice: "Note created successfully."
    else
      @note = note_params
      @notebooks = notes_client.notebooks
      @notebooks = @notebooks["notebooks"] || @notebooks if @notebooks.is_a?(Hash)
      @tags = cached_notes_tags
      @tags = @tags["tags"] || @tags if @tags.is_a?(Hash)
      @errors = result["errors"] || [ result["message"] ]
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @note = notes_client.note(params[:id])
    @notebooks = notes_client.notebooks
    @notebooks = @notebooks["notebooks"] || @notebooks if @notebooks.is_a?(Hash)
    @tags = cached_notes_tags
    @tags = @tags["tags"] || @tags if @tags.is_a?(Hash)
  end

  def update
    result = notes_client.update_note(params[:id], note_params.merge(tag_ids: params[:tag_ids]))
    if result["id"]
      redirect_to note_path(result["id"]), notice: "Note updated successfully."
    else
      @note = notes_client.note(params[:id])
      @notebooks = notes_client.notebooks
      @notebooks = @notebooks["notebooks"] || @notebooks if @notebooks.is_a?(Hash)
      @tags = cached_notes_tags
      @tags = @tags["tags"] || @tags if @tags.is_a?(Hash)
      @errors = result["errors"] || [ result["message"] ]
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    notes_client.delete_note(params[:id])
    redirect_to notes_path, notice: "Note deleted successfully."
  end

  def pin
    notes_client.pin_note(params[:id])
    redirect_back fallback_location: note_path(params[:id]), notice: "Note pinned."
  end

  def unpin
    notes_client.unpin_note(params[:id])
    redirect_back fallback_location: note_path(params[:id]), notice: "Note unpinned."
  end

  def favorite
    notes_client.favorite_note(params[:id])
    redirect_back fallback_location: note_path(params[:id]), notice: "Note favorited."
  end

  def unfavorite
    notes_client.unfavorite_note(params[:id])
    redirect_back fallback_location: note_path(params[:id]), notice: "Note unfavorited."
  end

  def duplicate
    result = notes_client.duplicate_note(params[:id])
    if result["id"]
      redirect_to note_path(result["id"]), notice: "Note duplicated."
    else
      redirect_to note_path(params[:id]), alert: "Failed to duplicate note."
    end
  end

  def share
    expires_in = params[:expires_in].presence
    result = notes_client.share_note(params[:id], expires_in: expires_in)
    if result["shared_token"].present?
      redirect_to note_path(params[:id]), notice: "Note shared! Public link is ready."
    else
      redirect_to note_path(params[:id]), notice: "Note shared."
    end
  end

  def unshare
    notes_client.unshare_note(params[:id])
    redirect_to note_path(params[:id]), notice: "Note is no longer shared."
  end

  def move
    notebook_id = params[:notebook_id]
    notes_client.move_note(params[:id], notebook_id)
    redirect_to note_path(params[:id]), notice: "Note moved successfully."
  end

  def export_markdown
    content = notes_client.export_note_markdown(params[:id])
    send_data content, filename: "note_#{params[:id]}.md", type: "text/markdown"
  end

  def export_html
    content = notes_client.export_note_html(params[:id])
    send_data content, filename: "note_#{params[:id]}.html", type: "text/html"
  end

  def export_json
    content = notes_client.export_note_json(params[:id])
    send_data content, filename: "note_#{params[:id]}.json", type: "application/json"
  end

  def pinboard
    threads = {}
    threads[:pinned] = Thread.new { notes_client.notes(pinned: true, per_page: 50) }
    threads[:favorited] = Thread.new { notes_client.notes(favorited: true, per_page: 50) }

    pinned_result = threads[:pinned].value
    favorited_result = threads[:favorited].value

    @pinned_notes = (pinned_result.is_a?(Hash) ? (pinned_result["notes"] || []) : pinned_result || [])
    favorited = (favorited_result.is_a?(Hash) ? (favorited_result["notes"] || []) : favorited_result || [])

    # Avoid duplicates - notes that are both pinned and favorited
    pinned_ids = @pinned_notes.map { |n| n["id"] }
    @favorited_notes = favorited.reject { |n| pinned_ids.include?(n["id"]) }
  end

  def search
    @query = params[:q]
    if @query.present?
      result = notes_client.search(params.permit(:q, :notebook_id, :tag_id, :page).to_h.compact_blank)
      @notes = result["notes"] || result
      @meta = result["meta"] || {}
    else
      @notes = []
      @meta = {}
    end
  end

  def productivity
    threads = {}
    threads[:stats] = Thread.new { notes_client.stats rescue {} }
    threads[:activity] = Thread.new { notes_client.activity_stats rescue [] }
    threads[:by_notebook] = Thread.new { notes_client.stats_by_notebook rescue [] }
    threads[:by_tag] = Thread.new { notes_client.stats_by_tag rescue [] }
    threads[:recent] = Thread.new { notes_client.notes(per_page: 100) rescue {} }

    stats_result = threads[:stats].value
    @stats = stats_result.is_a?(Hash) ? stats_result : {}
    activity_result = threads[:activity].value
    @activity = activity_result.is_a?(Array) ? activity_result : []
    nb_result = threads[:by_notebook].value
    @by_notebook = nb_result.is_a?(Array) ? nb_result : (nb_result.is_a?(Hash) ? (nb_result["stats"] || []) : [])
    tag_result = threads[:by_tag].value
    @by_tag = tag_result.is_a?(Array) ? tag_result : (tag_result.is_a?(Hash) ? (tag_result["stats"] || []) : [])
    recent_result = threads[:recent].value
    @recent_notes = recent_result.is_a?(Hash) ? (recent_result["notes"] || []) : (recent_result || [])

    # Build writing streak
    @writing_dates = @recent_notes.filter_map { |n|
      Date.parse(n["created_at"].to_s.slice(0, 10)) rescue nil
    }.uniq.sort.reverse

    @writing_streak = 0
    check_date = Date.current
    @writing_dates.each do |d|
      if d == check_date || d == check_date - 1
        @writing_streak += 1
        check_date = d - 1
      else
        break
      end
    end

    # Writing heatmap (last 90 days)
    @daily_notes = {}
    @recent_notes.each do |note|
      date = note["created_at"].to_s.slice(0, 10)
      next unless date.present?
      @daily_notes[date] = (@daily_notes[date] || 0) + 1
    end

    # Words written estimate
    @total_words = @stats["total_word_count"] || @recent_notes.sum { |n| n["word_count"].to_i }
  end

  def knowledge_graph
    threads = {}
    threads[:notes] = Thread.new { notes_client.notes(per_page: 200) }
    threads[:notebooks] = Thread.new { notes_client.notebooks rescue [] }

    result = threads[:notes].value
    notes = result.is_a?(Hash) ? (result["notes"] || []) : (result || [])
    nb = threads[:notebooks].value
    @notebooks = nb.is_a?(Hash) ? (nb["notebooks"] || nb) : (nb.is_a?(Array) ? nb : [])

    # Build graph data: nodes and edges
    # Each note is a node; backlinks ([[title]]) create edges
    title_to_id = {}
    notes.each { |n| title_to_id[n["title"].to_s.downcase] = n["id"] }

    @nodes = notes.map { |n|
      notebook = @notebooks.find { |nb| nb["id"].to_s == n["notebook_id"].to_s }
      {
        id: n["id"],
        title: n["title"] || "Untitled",
        notebook: notebook&.dig("name") || "Default",
        notebook_id: n["notebook_id"],
        word_count: n["word_count"].to_i,
        pinned: n["pinned"],
        favorited: n["favorited"],
        tags: (n["tags"] || []).map { |t| t["name"] }.compact
      }
    }

    @edges = []
    notes.each do |note|
      content = note["content"].to_s
      # Find [[wiki-style links]]
      content.scan(/\[\[([^\]]+)\]\]/).flatten.each do |ref|
        target_id = title_to_id[ref.downcase]
        if target_id && target_id != note["id"]
          @edges << { source: note["id"], target: target_id }
        end
      end
    end

    @edges.uniq!

    # Compute connection counts for sizing
    connection_counts = Hash.new(0)
    @edges.each do |e|
      connection_counts[e[:source]] += 1
      connection_counts[e[:target]] += 1
    end
    @nodes.each { |n| n[:connections] = connection_counts[n[:id]] }

    # Stats
    @total_notes = notes.count
    @connected_notes = connection_counts.keys.count
    @total_links = @edges.count
    @most_connected = @nodes.max_by { |n| n[:connections] }
    @orphan_count = @nodes.count { |n| n[:connections] == 0 }
  end

  def bulk_tag
    result = notes_client.bulk_tag_notes(params[:note_ids], params[:tag_ids])
    render json: result
  end

  def bulk_move
    result = notes_client.bulk_move_notes(params[:note_ids], params[:notebook_id])
    render json: result
  end

  def bulk_delete
    result = notes_client.bulk_delete_notes(params[:note_ids])
    render json: result
  end

  def bulk_favorite
    result = notes_client.bulk_favorite_notes(params[:note_ids], params[:favorited])
    render json: result
  end

  def bulk_pin
    result = notes_client.bulk_pin_notes(params[:note_ids], params[:pinned])
    render json: result
  end

  private

  def note_params
    params.require(:note).permit(
      :title, :content, :notebook_id, :pinned, :favorited, :color
    ).to_h.compact_blank
  end
end
