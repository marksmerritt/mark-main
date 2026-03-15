module Budget
  class GoalsController < ApplicationController
    before_action :require_budget_connection

    def index
      threads = {}
      threads[:goals] = Thread.new { budget_client.goals(status: params[:status], goal_type: params[:goal_type]) }
      threads[:funds] = Thread.new { budget_client.funds(status: "active") }
      threads[:debts] = Thread.new { budget_client.debt_accounts(status: "active") }

      @goals = threads[:goals].value
      @funds = threads[:funds].value
      @debts = threads[:debts].value
    end

    def show
      @goal = budget_client.goal(params[:id])
    end

    def new
      threads = {}
      threads[:funds] = Thread.new { budget_client.funds(status: "active") }
      threads[:debts] = Thread.new { budget_client.debt_accounts(status: "active") }

      @goal = {}
      @funds = threads[:funds].value
      @debts = threads[:debts].value
    end

    def create
      result = budget_client.create_goal(goal_params)
      if result["id"]
        redirect_to budget_goal_path(result["id"]), notice: "Goal created."
      else
        threads = {}
        threads[:funds] = Thread.new { budget_client.funds(status: "active") }
        threads[:debts] = Thread.new { budget_client.debt_accounts(status: "active") }

        @goal = goal_params
        @funds = threads[:funds].value
        @debts = threads[:debts].value
        @errors = result["errors"] || [result["message"]]
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      threads = {}
      threads[:goal] = Thread.new { budget_client.goal(params[:id]) }
      threads[:funds] = Thread.new { budget_client.funds(status: "active") }
      threads[:debts] = Thread.new { budget_client.debt_accounts(status: "active") }

      @goal = threads[:goal].value
      @funds = threads[:funds].value
      @debts = threads[:debts].value
    end

    def update
      result = budget_client.update_goal(params[:id], goal_params)
      if result["id"]
        redirect_to budget_goal_path(result["id"]), notice: "Goal updated."
      else
        threads = {}
        threads[:goal] = Thread.new { budget_client.goal(params[:id]) }
        threads[:funds] = Thread.new { budget_client.funds(status: "active") }
        threads[:debts] = Thread.new { budget_client.debt_accounts(status: "active") }

        @goal = threads[:goal].value
        @funds = threads[:funds].value
        @debts = threads[:debts].value
        @errors = result["errors"] || [result["message"]]
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      budget_client.delete_goal(params[:id])
      redirect_to budget_goals_path, notice: "Goal deleted."
    end

    def sync
      result = budget_client.sync_goal(params[:id])
      if result["error"]
        redirect_to budget_goal_path(params[:id]), alert: "Sync failed."
      else
        redirect_to budget_goal_path(params[:id]), notice: "Goal synced with linked account."
      end
    end

    private

    def goal_params
      params.require(:goal).permit(
        :name, :goal_type, :target_amount, :current_amount,
        :target_date, :status, :icon, :notes,
        :linked_fund_id, :linked_debt_id
      ).to_h.compact_blank
    end
  end
end
