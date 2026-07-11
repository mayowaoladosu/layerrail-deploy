Rails.application.routes.draw do
  get "health" => "health#show", as: :health

  namespace :api, path: nil do
    namespace :v1, path: "v1" do
      resources :projects, only: :create
      post "services/:service_id/deployments" => "deployments#create"
      get "deployments/:deployment_id" => "deployments#show"
      post "deployments/:deployment_id/cancel" => "deployments#cancel"
      post "environments/:environment_id/promotions" => "environment_operations#promote"
      post "environments/:environment_id/rollbacks" => "environment_operations#rollback"
    end
  end

  namespace :webhooks do
    resource :github, only: :create, controller: :github
  end

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
