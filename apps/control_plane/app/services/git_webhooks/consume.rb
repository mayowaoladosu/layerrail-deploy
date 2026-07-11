module GitWebhooks
  class Consume
    Result = Data.define(:deployment, :event, :replayed, :ignored)

    def self.call(message:)
      new(message:).call
    end

    def initialize(message:)
      @message = message
    end

    def call
      ApplicationRecord.transaction(requires_new: true) do
        @message.lock!
        return replay if @message.status == "processed"
        return Result.new(deployment: nil, event: nil, replayed: true, ignored: true) if @message.status == "failed"

        source = deployment_source
        return ignore_message unless source

        connection = active_connection
        return fail_message("Repository is not connected") unless connection

        environment = environment_for(connection, source.fetch("reference"))
        return ignore_message unless environment

        context = AuthorizationContext.system(organization: @message.organization)
        deployment = Deployments::Create.call(
          context:,
          service: connection.service,
          environment:,
          source:,
          idempotency_key: "webhook:#{@message.provider}:#{@message.delivery_id}",
          correlation_id: @message.id,
          trigger: :webhook
        ).deployment
        event = request_event(deployment)
        @message.update!(
          status: :processed,
          deployment:,
          processed_at: Time.current,
          safe_error: nil
        )

        Result.new(deployment:, event:, replayed: false, ignored: false)
      end
    rescue Deployments::Create::InvalidSource
      ApplicationRecord.transaction(requires_new: true) do
        @message.lock!
        fail_message("Webhook source is invalid")
      end
    end

    private

    def replay
      deployment = @message.deployment
      Result.new(
        deployment:,
        event: deployment ? request_event(deployment) : nil,
        replayed: true,
        ignored: deployment.nil?
      )
    end

    def active_connection
      RepositoryConnection.find_by(
        organization_id: @message.organization_id,
        git_installation_id: @message.git_installation_id,
        provider_repository_id: @message.provider_repository_id,
        status: "active"
      )
    end

    def deployment_source
      case @message.event_type
      when "git.push.v1"
        git_source(reference: @message.data.fetch("ref"), commit_sha: @message.data.fetch("after_sha"))
      when "git.pull_request.v1"
        return unless @message.data.fetch("action").in?(%w[opened reopened synchronize])

        git_source(
          reference: @message.data.fetch("head_ref"),
          commit_sha: @message.data.fetch("head_sha")
        )
      end
    end

    def git_source(reference:, commit_sha:)
      {
        "type" => "git",
        "reference" => reference,
        "commit_sha" => commit_sha,
        "repository_id" => @message.provider_repository_id
      }
    end

    def environment_for(connection, branch)
      project = connection.project
      explicit = project.environments.find_by(branch:)
      return explicit if explicit

      if @message.event_type == "git.pull_request.v1"
        project.environments.find_by(kind: :staging)
      elsif branch == connection.default_branch
        project.environments.find_by(kind: :production)
      end
    end

    def request_event(deployment)
      OutboxEvent.find_by!(
        organization_id: deployment.organization_id,
        resource_id: deployment.id,
        event_type: "deployment.requested.v1"
      )
    end

    def ignore_message
      @message.update!(status: :processed, processed_at: Time.current, safe_error: nil)
      Result.new(deployment: nil, event: nil, replayed: false, ignored: true)
    end

    def fail_message(safe_error)
      @message.update!(
        status: :failed,
        deployment: nil,
        processed_at: Time.current,
        safe_error:
      )
      Result.new(deployment: nil, event: nil, replayed: false, ignored: true)
    end
  end
end
