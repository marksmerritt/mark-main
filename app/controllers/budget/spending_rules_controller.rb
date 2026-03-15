module Budget
  class SpendingRulesController < ApplicationController
    before_action :require_budget_connection

    def index
      threads = {}
      threads[:rules] = Thread.new { budget_client.spending_rules }
      threads[:violations] = Thread.new { budget_client.evaluate_spending_rules }
      @rules = threads[:rules].value
      @violations = threads[:violations].value
      @rules = [] unless @rules.is_a?(Array)
    end

    def new
      @rule = {}
    end

    def create
      result = budget_client.create_spending_rule(rule_params)
      if result["id"]
        redirect_to budget_spending_rules_path, notice: "Rule created."
      else
        @rule = rule_params
        @errors = result["errors"] || [result["message"]]
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @rule = budget_client.spending_rule(params[:id])
    end

    def update
      result = budget_client.update_spending_rule(params[:id], rule_params)
      if result["id"]
        redirect_to budget_spending_rules_path, notice: "Rule updated."
      else
        @rule = budget_client.spending_rule(params[:id])
        @errors = result["errors"] || [result["message"]]
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      budget_client.delete_spending_rule(params[:id])
      redirect_to budget_spending_rules_path, notice: "Rule deleted."
    end

    private

    def rule_params
      params.require(:spending_rule).permit(
        :name, :rule_type, :threshold, :period,
        :merchant_pattern, :category_name, :active
      ).to_h.compact_blank
    end
  end
end
