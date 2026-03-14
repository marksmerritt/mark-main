class TagsController < ApplicationController
  before_action :require_api_connection

  def index
    @tags = api_client.tags
  end

  def show
    @tag = api_client.tag(params[:id])
  end

  def new
    @tag = {}
  end

  def create
    result = api_client.create_tag(tag_params)
    if result["id"]
      redirect_to tag_path(result["id"]), notice: "Tag created successfully."
    else
      @tag = tag_params
      @errors = result["errors"] || [ result["message"] ]
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @tag = api_client.tag(params[:id])
  end

  def update
    result = api_client.update_tag(params[:id], tag_params)
    if result["id"]
      redirect_to tag_path(result["id"]), notice: "Tag updated successfully."
    else
      @tag = api_client.tag(params[:id])
      @errors = result["errors"] || [ result["message"] ]
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    api_client.delete_tag(params[:id])
    redirect_to tags_path, notice: "Tag deleted successfully."
  end

  private

  def tag_params
    params.require(:tag).permit(:name, :color).to_h.compact_blank
  end
end
