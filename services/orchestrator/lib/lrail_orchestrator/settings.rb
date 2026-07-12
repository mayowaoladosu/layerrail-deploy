# frozen_string_literal: true

require "uri"

module LrailOrchestrator
  class Settings
    attr_reader :temporal_address,
      :temporal_namespace,
      :task_queue,
      :control_plane_url,
      :control_plane_host,
      :shared_secret_path,
      :poll_interval

    def self.from_env
      new(
        temporal_address: ENV.fetch("TEMPORAL_ADDRESS", "temporal:7233"),
        temporal_namespace: ENV.fetch("TEMPORAL_NAMESPACE", "lrail-alpha"),
        task_queue: ENV.fetch("TEMPORAL_TASK_QUEUE", "lrail-deployments-v1"),
        control_plane_url: ENV.fetch("CONTROL_PLANE_URL", "http://control-plane:3000"),
        control_plane_host: ENV["CONTROL_PLANE_HTTP_HOST"],
        shared_secret_path: ENV.fetch(
          "ORCHESTRATOR_SHARED_SECRET_FILE",
          "/run/lrail-orchestrator-auth/secret"
        ),
        poll_interval: Float(ENV.fetch("ORCHESTRATOR_POLL_INTERVAL", "0.5"))
      )
    end

    def initialize(
      temporal_address:,
      temporal_namespace:,
      task_queue:,
      control_plane_url:,
      shared_secret_path:,
      poll_interval:,
      control_plane_host: nil
    )
      @temporal_address = bounded(temporal_address, 255)
      @temporal_namespace = identifier(temporal_namespace, 63)
      @task_queue = identifier(task_queue, 120)
      @control_plane_url = validated_url(control_plane_url)
      @control_plane_host = control_plane_host&.then { |value| bounded(value, 255) }
      @shared_secret_path = shared_secret_path.to_s
      @poll_interval = poll_interval
      raise ArgumentError, "secret path must be absolute" unless @shared_secret_path.start_with?("/")
      raise ArgumentError, "poll interval is invalid" unless @poll_interval.between?(0.05, 30.0)
    end

    private

    def bounded(value, maximum)
      value = value.to_s
      raise ArgumentError, "setting is invalid" if value.empty? || value.bytesize > maximum

      value.freeze
    end

    def identifier(value, maximum)
      value = bounded(value, maximum)
      raise ArgumentError, "identifier is invalid" unless value.match?(/\A[a-z][a-z0-9._-]*\z/)

      value
    end

    def validated_url(value)
      value = bounded(value, 2048)
      uri = URI.parse(value)
      unless uri.is_a?(URI::HTTP) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
        raise ArgumentError, "control plane URL is invalid"
      end

      value.delete_suffix("/").freeze
    rescue URI::InvalidURIError
      raise ArgumentError, "control plane URL is invalid"
    end
  end
end
