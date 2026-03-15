module Budget
  class TagsController < ApplicationController
    before_action :require_budget_connection

    def index
      result = budget_client.tags
      @tags = result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["tags"] || []) : [])
      @tags = @tags.sort_by { |t| t["name"].to_s.downcase }
    end

    def create
      result = budget_client.create_tag(tag_params)
      if result["id"]
        redirect_to budget_tags_path, notice: "Tag created."
      else
        redirect_to budget_tags_path, alert: result["message"] || "Failed to create tag."
      end
    end

    def update
      result = budget_client.update_tag(params[:id], tag_params)
      if result["id"]
        redirect_to budget_tags_path, notice: "Tag updated."
      else
        redirect_to budget_tags_path, alert: result["message"] || "Failed to update tag."
      end
    end

    def destroy
      budget_client.delete_tag(params[:id])
      redirect_to budget_tags_path, notice: "Tag deleted."
    end

    private

    def tag_params
      params.require(:tag).permit(:name, :color).to_h.compact_blank
    end
  end
end
