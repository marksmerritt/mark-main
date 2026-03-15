Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest

  # Trading Journal
  resources :trades do
    member do
      post :submit_review
    end
    collection do
      get :import_wizard
      post :import
      get :export
      post :bulk_tag
      post :bulk_delete
      get :review
      get :review_stats
    end
  end

  scope "trades/:trade_id", controller: :trades do
    post "screenshots", action: :create_screenshot, as: :trade_screenshots
    delete "screenshots/:id", action: :destroy_screenshot, as: :trade_screenshot
  end
  resources :journal_entries do
    collection do
      get :calendar
    end
  end
  resources :tags
  resources :trade_plans do
    member do
      post :execute
    end
  end
  resources :watchlists
  resources :playbooks

  get 'position_calculator', to: 'position_calculator#index'
  post 'position_calculator', to: 'position_calculator#calculate'

  scope :reports, controller: :reports, as: :reports do
    get :index, path: ""
    get :overview
    get :by_symbol
    get :by_tag
    get :equity_curve
    get :risk_analysis
    get :by_time
    get :by_duration
    get :heatmap
    get :monte_carlo
    get :distribution
    get :weekly_summary
    get :scorecard
    get :setup_analysis
    get :correlation
    get :risk_reward
    get :streak_analysis
    get :monthly_performance
    get :pnl_calendar
    get :period_comparison
    get :execution_quality
    get :mood_analytics
    get :fee_analysis
    get :risk_of_ruin
    get :expectancy
    get :discipline
    get :position_sizing
    get :leaderboard
    get :habits
    get :session_log
    get :playbook_performance
    get :equity_breakdown
    get :what_if
  end

  # Notes
  resources :notes do
    collection do
      get :pinboard
      get :productivity
      get :knowledge_graph
      post :bulk_tag
      post :bulk_move
      post :bulk_delete
      post :bulk_favorite
      post :bulk_pin
    end
    member do
      post :pin
      post :unpin
      post :favorite
      post :unfavorite
      post :duplicate
      post :share
      post :unshare
      post :move
      get :export_markdown
      get :export_html
      get :export_json
    end
    resources :note_versions, only: [:index, :show] do
      member do
        post :revert
      end
    end
  end
  resources :note_notebooks
  resources :note_tags, only: [:index, :create, :update, :destroy]

  resources :note_templates, only: [:index, :new, :create, :edit, :update, :destroy] do
    member do
      post :apply
    end
  end

  resources :trash, only: [:index] do
    member do
      post :restore
    end
    collection do
      delete :empty
    end
  end

  resources :reminders, only: [:index, :create, :update, :destroy]

  scope :notes_search, controller: :notes, as: :notes_search do
    get :search
  end

  get "exposure", to: "exposure#index"
  get "risk_dashboard", to: "risk_dashboard#index"
  get "pre_market", to: "pre_market#show"
  get "monthly_report", to: "monthly_report#show"
  get "timeline", to: "timeline#index"
  get "milestones", to: "milestones#index"
  get "search", to: "search#index"
  get "quick_search", to: "quick_search#index"

  # Trade comparison
  get "comparison", to: "comparison#show"
  get "symbol_comparison", to: "symbol_comparison#show"
  get "trade_compare", to: "trade_compare#show"
  get "trade_replay", to: "trade_replay#show"
  get "position_risk", to: "position_risk#show"
  get "trade_correlations", to: "trade_correlations#show"
  get "account_summary", to: "account_summary#show"
  get "journal_insights", to: "journal_insights#show"
  get "trading_grades", to: "trading_grades#show"
  get "trading_challenges", to: "trading_challenges#show"
  get "financial_pulse", to: "financial_pulse#show"
  get "trade_checklist", to: "trade_checklist#show"
  get "tax_estimator", to: "tax_estimator#show"
  get "trading_costs", to: "trading_costs#show"
  get "market_regime", to: "market_regime#show"
  get "edge_finder", to: "edge_finder#show"
  get "performance_heatmap", to: "performance_heatmap#show"
  get "trade_simulator", to: "trade_simulator#show"
  get "trade_feed", to: "trade_feed#show"
  get "trading_mentor", to: "trading_mentor#show"
  get "journal_templates", to: "journal_templates#index"
  get "writing_stats", to: "writing_stats#show"
  get "writing_digest", to: "writing_digest#show"
  get "writing_prompts", to: "writing_prompts#show"
  get "reading_stats", to: "reading_stats#show"
  get "note_links", to: "note_links#show"
  get "note_maintenance", to: "note_maintenance#show"
  get "note_export_center", to: "note_export_center#show"
  get "note_flashcards", to: "note_flashcards#show"
  get "note_bookmarks", to: "note_bookmarks#show"
  get "note_sentiment", to: "note_sentiment#show"
  get "note_topics", to: "note_topics#show"
  get "word_frequency", to: "word_frequency#show"
  get "writing_goals", to: "writing_goals#show"
  get "focus_timer", to: "focus_timer#show"
  get "loss_recovery", to: "loss_recovery#show"
  get "rr_optimizer", to: "rr_optimizer#show"
  get "session_analyzer", to: "session_analyzer#show"
  get "breakeven_analyzer", to: "breakeven_analyzer#show"
  get "wl_patterns", to: "wl_patterns#show"
  get "entry_timing", to: "entry_timing#show"
  get "habit_tracker", to: "habit_tracker#show"
  get "portfolio_overview", to: "portfolio_overview#show"
  get "goal_tracker", to: "goal_tracker#show"
  get "performance_benchmarks", to: "performance_benchmarks#show"
  get "trend_analyzer", to: "trend_analyzer#show"
  get "mood_performance", to: "mood_performance#show"
  get "smart_alerts", to: "smart_alerts#show"
  get "sizing_advisor", to: "sizing_advisor#show"
  get "cross_product_insights", to: "cross_product_insights#show"
  get "weekly_planner", to: "weekly_planner#show"
  get "strategy_builder", to: "strategy_builder#show"
  get "morning_briefing", to: "morning_briefing#show"
  get "account_health", to: "account_health#show"
  get "profit_targets", to: "profit_targets#show"
  get "achievements", to: "achievements#show"
  get "drawdown_tracker", to: "drawdown_tracker#show"
  get "performance_attribution", to: "performance_attribution#show"
  get "journal_prompts", to: "journal_prompts#show"
  get "risk_rules", to: "risk_rules#show"
  get "market_session", to: "market_session#show"
  get "trade_calendar", to: "trade_calendar#show"
  get "correlation_matrix", to: "correlation_matrix#show"
  get "win_loss_analysis", to: "win_loss_analysis#show"
  get "spending_trading", to: "spending_trading#show"
  get "trade_templates", to: "trade_templates#show"
  get "snapshot_report", to: "snapshot_report#show"
  get "equity_simulator", to: "equity_simulator#show"
  get "playbook_comparison", to: "playbook_comparison#show"
  get "streak_calendar", to: "streak_calendar#show"
  get "sizing_backtest", to: "sizing_backtest#show"
  get "consistency_report", to: "consistency_report#show"
  get "symbol_deep_dive", to: "symbol_deep_dive#show"

  # Data export
  scope :data_export, controller: :data_export, as: :data_export do
    get :index, path: ""
    get :trades_csv
    get :journal_csv
    get :notes_json
    get :playbooks_md
    get :budget_transactions_csv
    get :budget_summary_json
    get :account_statement
  end

  # Public shared note viewer (no auth needed)
  get "shared/:shared_token", to: "shared_notes#show", as: :shared_note

  # Budget
  namespace :budget do
    get "/", to: "dashboard#index", as: :dashboard
    get "calendar", to: "dashboard#calendar", as: :calendar
    get "financial_calendar", to: "dashboard#financial_calendar", as: :financial_calendar
    get "savings", to: "dashboard#savings", as: :savings
    get "emergency_fund", to: "calculators#emergency_fund", as: :emergency_fund
    get "debt_freedom", to: "calculators#debt_freedom", as: :debt_freedom
    get "wellness_scorecard", to: "calculators#wellness_scorecard", as: :wellness_scorecard
    get "spending_heatmap", to: "calculators#spending_heatmap", as: :spending_heatmap
    get "savings_projection", to: "calculators#savings_projection", as: :savings_projection
    get "net_worth_forecast", to: "calculators#net_worth_forecast", as: :net_worth_forecast
    get "spending_anomalies", to: "calculators#spending_anomalies", as: :spending_anomalies
    get "income_allocator", to: "calculators#income_allocator", as: :income_allocator
    get "goal_planner", to: "calculators#goal_planner", as: :goal_planner
    get "recurring_analyzer", to: "calculators#recurring_analyzer", as: :recurring_analyzer
    get "expense_forecast", to: "calculators#expense_forecast", as: :expense_forecast
    get "bill_splitter", to: "calculators#bill_splitter", as: :bill_splitter
    get "subscription_manager", to: "calculators#subscription_manager", as: :subscription_manager
    get "savings_challenges", to: "calculators#savings_challenges", as: :savings_challenges
    get "cash_flow_planner", to: "calculators#cash_flow_planner", as: :cash_flow_planner
    get "spending_personality", to: "calculators#spending_personality", as: :spending_personality
    get "year_in_review", to: "calculators#year_in_review", as: :year_in_review
    get "debt_visualizer", to: "calculators#debt_visualizer", as: :debt_visualizer
    get "lifestyle_inflation", to: "calculators#lifestyle_inflation", as: :lifestyle_inflation
    get "fire_calculator", to: "calculators#fire_calculator", as: :fire_calculator
    get "purchase_advisor", to: "calculators#purchase_advisor", as: :purchase_advisor
    get "net_worth_dashboard", to: "calculators#net_worth_dashboard", as: :net_worth_dashboard
    get "money_calendar", to: "calculators#money_calendar", as: :money_calendar
    get "impulse_tracker", to: "calculators#impulse_tracker", as: :impulse_tracker
    get "paycheck_planner", to: "calculators#paycheck_planner", as: :paycheck_planner
    get "forecast_accuracy", to: "calculators#forecast_accuracy", as: :forecast_accuracy
    get "spending_watchdog", to: "calculators#spending_watchdog", as: :spending_watchdog
    get "allocate", to: "dashboard#allocate", as: :allocate
    post "allocate", to: "dashboard#apply_allocation", as: :apply_allocation
    resources :budgets do
      member do
        post :copy
        post :rollover
        get :rollover, action: :rollover, defaults: { preview: true }, as: :rollover_preview
      end
      resources :budget_categories, only: [:create, :update, :destroy] do
        resources :budget_items, only: [:create, :update, :destroy]
      end
    end
    resources :transactions, except: [:show] do
      member do
        post :split
        post :unsplit
        post :add_tag
        delete :remove_tag
      end
      collection do
        get :import_wizard
        get :export
        post :import
        post :bulk_assign
        post :bulk_delete
        get :merchants
        get :search
      end
    end
    resources :funds do
      member do
        post :contribute
      end
    end
    resources :debt_accounts do
      member do
        post :pay
      end
      collection do
        get :snowball
        get :avalanche
        get :compare_plans
      end
    end
    resources :goals do
      member do
        post :sync
      end
    end
    resources :recurring, only: [:index, :new, :create, :edit, :update, :destroy] do
      member do
        post :skip
      end
      collection do
        get :calendar
        post :auto_process
      end
    end

    resources :challenges, only: [:index, :show, :new, :create, :destroy] do
      member do
        post :evaluate
        post :abandon
      end
    end

    resources :tags, only: [:index, :create, :update, :destroy]
    resources :spending_rules
    resources :merchant_insights, only: [:index]

    resources :alerts, only: [:index, :destroy] do
      member do
        post :mark_read
        post :acknowledge
      end
      collection do
        post :mark_read
        delete :clear
      end
    end

    scope :reports, controller: "reports", as: :reports do
      get :spending
      get :net_worth
      post :take_snapshot
      get :income_vs_expenses
      get :comparison
      get :merchants
      get :forecast
      get :insights
      get :year_over_year
      get :digest
      get :subscription_audit
      get :bill_tracker
      get :cash_flow
      get :annual_review
      get :spending_velocity
      get :category_drill
      get :income_tracker
      get :spending_patterns
      get :net_worth_details
    end
  end

  get "notifications", to: "notifications#index"

  get "digest", to: "digest#show"
  get "weekly_report", to: "weekly_report#show"
  get "daily_review", to: "daily_review#show"
  get "weekly_planner", to: "weekly_planner#show"

  get "settings", to: "settings#index"
  get "getting_started", to: "getting_started#index"

  root "home#index"
end
