class NoteTemplatesController < ApplicationController
  before_action :require_notes_connection

  def index
    result = notes_client.note_templates
    @templates = result.is_a?(Array) ? result : (result["note_templates"] || [])
  end

  def new
    @template = {}
    @categories = %w[meeting project journal checklist blank]
  end

  def create
    result = notes_client.create_template(template_params)
    if result["id"]
      redirect_to note_templates_path, notice: "Template created."
    else
      redirect_to new_note_template_path, alert: result["message"] || "Failed to create template."
    end
  end

  def edit
    result = notes_client.note_template(params[:id])
    if result["id"]
      @template = result
      @categories = %w[meeting project journal checklist blank]
    else
      redirect_to note_templates_path, alert: "Template not found."
    end
  end

  def update
    result = notes_client.update_template(params[:id], template_params)
    if result["id"]
      redirect_to note_templates_path, notice: "Template updated."
    else
      redirect_to edit_note_template_path(params[:id]), alert: result["message"] || "Failed to update template."
    end
  end

  def destroy
    notes_client.delete_template(params[:id])
    redirect_to note_templates_path, notice: "Template deleted."
  end

  def apply
    @notebooks = notes_client.notebooks
    @notebooks = @notebooks.is_a?(Array) ? @notebooks : (@notebooks["notebooks"] || [])

    notebook_id = params[:notebook_id] || @notebooks.first&.dig("id")
    result = notes_client.apply_template(params[:id], notebook_id)

    if result["id"]
      redirect_to note_path(result["id"]), notice: "Note created from template."
    else
      redirect_to note_templates_path, alert: "Failed to apply template."
    end
  end

  private

  def template_params
    params.require(:note_template).permit(:name, :description, :content, :category, :is_default).to_h.compact_blank
  end
end
