module Budget
  class ChallengesController < ApplicationController
    before_action :require_budget_connection

    def index
      threads = {}
      threads[:active] = Thread.new { budget_client.savings_challenges(active: "true") }
      threads[:completed] = Thread.new { budget_client.savings_challenges }
      threads[:presets] = Thread.new { budget_client.challenge_presets }

      @active = threads[:active].value
      @all = threads[:completed].value
      @presets = threads[:presets].value
      @active = [] unless @active.is_a?(Array)
      @all = [] unless @all.is_a?(Array)
      @presets = [] unless @presets.is_a?(Array)
    end

    def show
      @challenge = budget_client.savings_challenge(params[:id])
    end

    def new
      @challenge = {}
      @presets = budget_client.challenge_presets
      @presets = [] unless @presets.is_a?(Array)
    end

    def create
      if params[:preset].present?
        result = budget_client.create_challenge_from_preset(params[:preset], start_date: params[:start_date])
      else
        result = budget_client.create_savings_challenge(challenge_params)
      end

      if result["id"]
        redirect_to budget_challenge_path(result["id"]), notice: "Challenge started!"
      else
        @challenge = challenge_params
        @presets = budget_client.challenge_presets rescue []
        @errors = result["errors"] || [result["message"]]
        render :new, status: :unprocessable_entity
      end
    end

    def destroy
      budget_client.delete_savings_challenge(params[:id])
      redirect_to budget_challenges_path, notice: "Challenge deleted."
    end

    def evaluate
      budget_client.evaluate_challenge(params[:id])
      redirect_to budget_challenge_path(params[:id]), notice: "Challenge evaluated."
    end

    def abandon
      budget_client.abandon_challenge(params[:id])
      redirect_to budget_challenges_path, notice: "Challenge abandoned."
    end

    private

    def challenge_params
      params.require(:savings_challenge).permit(
        :name, :challenge_type, :start_date, :end_date,
        :target_amount, :notes
      ).to_h.compact_blank
    end
  end
end
