class NoteTagsController < ApplicationController
  before_action :require_notes_connection

  def index
    threads = {}
    threads[:tags] = Thread.new { notes_client.tags }
    threads[:stats] = Thread.new { notes_client.stats_by_tag rescue [] }

    tags_result = threads[:tags].value
    @tags = tags_result.is_a?(Hash) ? (tags_result["tags"] || tags_result) : (tags_result.is_a?(Array) ? tags_result : [])
    stats_result = threads[:stats].value
    @tag_stats = stats_result.is_a?(Array) ? stats_result : (stats_result.is_a?(Hash) ? (stats_result["stats"] || []) : [])
  end

  def create
    result = notes_client.create_tag(tag_params)
    if result["id"]
      redirect_to note_tags_path, notice: "Tag created."
    else
      redirect_to note_tags_path, alert: result["message"] || "Failed to create tag."
    end
  end

  def update
    result = notes_client.update_tag(params[:id], tag_params)
    if result["id"]
      redirect_to note_tags_path, notice: "Tag updated."
    else
      redirect_to note_tags_path, alert: result["message"] || "Failed to update tag."
    end
  end

  def destroy
    notes_client.delete_tag(params[:id])
    redirect_to note_tags_path, notice: "Tag deleted."
  end

  private

  def tag_params
    params.require(:tag).permit(:name, :color).to_h.compact_blank
  end
end
