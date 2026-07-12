Rails.application.routes.draw do
  get "legacy-assets/*filename" => "legacy_assets#show", as: :legacy_asset, format: false
  root "home#index"
  get "health" => "health#show", as: :health
  get "health/orchestrator" => "health#orchestrator"

  namespace :api, path: nil do
    namespace :v1, path: "v1" do
      post "auth/challenges" => "authentication#challenge"
      post "auth/sessions" => "authentication#create"
      delete "auth/session" => "authentication#destroy"
      get "auth/me" => "authentication#show"
      resources :projects, only: :create
      post "services/:service_id/deployments" => "deployments#create"
      get "deployments/:deployment_id" => "deployments#show"
      get "deployments/:deployment_id/logs" => "deployment_logs#index"
      post "deployments/:deployment_id/cancel" => "deployments#cancel"
      post "environments/:environment_id/promotions" => "environment_operations#promote"
      post "environments/:environment_id/rollbacks" => "environment_operations#rollback"
    end
  end

  namespace :webhooks do
    resource :github, only: :create, controller: :github
  end

  namespace :internal do
    namespace :v1 do
      post "local-provider/commands/claim" => "local_provider_commands#claim"
      post "local-provider/commands/:event_id/finalize" => "local_provider_commands#finalize"
      post "local-provider/events" => "local_provider_events#create"
      post "orchestrator/commands/claim" => "orchestrator_commands#claim"
      post "orchestrator/commands/:event_id/finalize" => "orchestrator_commands#finalize"
      post "orchestrator/operations" => "orchestrator_operations#create"
    end
  end

  resources :organizations, only: [] do
    resources :deployments, only: %i[index show] do
      member do
        get :live
        get :download_logs
        post :cancel, controller: :deployment_actions
        post :redeploy, controller: :deployment_actions
        post :promote, controller: :deployment_actions
        post :rollback, controller: :deployment_actions
      end
    end
  end

  get "auth/check-email" => "auth_pages#check_email", as: :auth_check_email

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"

  get ":team_slug/projects/:project_name/deployments/:id/live" => "deployments#live", as: :live_project_deployment
  get ":team_slug/projects/:project_name/deployments/:id/logs" => "deployments#download_logs", as: :project_deployment_logs
  post ":team_slug/projects/:project_name/deployments/:id/cancel" => "deployment_actions#cancel", as: :cancel_project_deployment
  post ":team_slug/projects/:project_name/deployments/:id/redeploy" => "deployment_actions#redeploy", as: :redeploy_project_deployment
  post ":team_slug/projects/:project_name/deployments/:id/promote" => "deployment_actions#promote", as: :promote_project_deployment
  post ":team_slug/projects/:project_name/deployments/:id/rollback" => "deployment_actions#rollback", as: :rollback_project_deployment
  get ":team_slug/projects/:project_name/deployments/:id" => "deployments#show", as: :project_deployment
  get ":team_slug/projects/:project_name/deployments" => "deployments#index", as: :project_deployments
  get ":team_slug/projects/:project_name" => "projects#show", as: :project
  get ":team_slug/projects" => "teams#projects", as: :team_projects
  get ":team_slug" => "teams#show", as: :team
end
