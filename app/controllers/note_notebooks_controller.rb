class NoteNotebooksController < ApplicationController
  before_action :require_notes_connection

  def index
    result = notes_client.notebooks
    @notebooks = result["notebooks"] || result
  end

  def show
    @notebook = notes_client.notebook(params[:id])
    result = notes_client.notes(notebook_id: params[:id])
    @notes = result["notes"] || result
    @meta = result["meta"] || {}
  end

  def new
    @notebook = {}
  end

  def create
    result = notes_client.create_notebook(notebook_params)
    if result["id"]
      redirect_to note_notebook_path(result["id"]), notice: "Notebook created successfully."
    else
      @notebook = notebook_params
      @errors = result["errors"] || [ result["message"] ]
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @notebook = notes_client.notebook(params[:id])
  end

  def update
    result = notes_client.update_notebook(params[:id], notebook_params)
    if result["id"]
      redirect_to note_notebook_path(result["id"]), notice: "Notebook updated successfully."
    else
      @notebook = notes_client.notebook(params[:id])
      @errors = result["errors"] || [ result["message"] ]
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    notes_client.delete_notebook(params[:id])
    redirect_to note_notebooks_path, notice: "Notebook deleted successfully."
  end

  private

  def notebook_params
    params.require(:notebook).permit(:name, :description).to_h.compact_blank
  end
end
