module ApplicationHelper
  def deployment_status_label(status)
    {
      "created" => "Created",
      "queued" => "Queued",
      "preparing" => "Preparing",
      "building" => "Building",
      "scanning" => "Verifying artifact",
      "deploying" => "Starting",
      "verifying" => "Checking readiness",
      "ready" => "Ready",
      "promoted" => "Live",
      "superseded" => "Superseded",
      "canceling" => "Canceling",
      "canceled" => "Canceled",
      "failed" => "Failed"
    }.fetch(status)
  end

  def deployment_status_tone(status)
    return "success" if status.in?(%w[ready promoted])
    return "danger" if status == "failed"
    return "muted" if status.in?(%w[superseded canceled])
    return "warning" if status.in?(%w[canceling scanning verifying])

    "progress"
  end

  def deployment_source_label(deployment)
    source = deployment.source_snapshot
    if source["type"] == "git"
      "#{source.fetch("reference")} · #{source.fetch("commit_sha").first(10)}"
    else
      digest = source.fetch("digest").delete_prefix("sha256:")
      "OCI · #{source.fetch("reference")}@#{digest.first(12)}"
    end
  end

  def deployment_author(transitions, actors)
    initial = transitions.first
    return "System" unless initial&.actor_type == "user"

    actor = actors[initial.actor_id]
    actor&.name.presence || actor&.email || "Former member"
  end

  def display_timestamp(value)
    value&.utc&.strftime("%b %-d, %Y · %H:%M:%S UTC") || "Not available"
  end

  def deployment_duration(deployment, transitions)
    completed = transitions.find { |transition| transition.to_status.in?(%w[ready canceled failed]) }
    finish = completed&.occurred_at || Time.current
    distance_of_time_in_words(deployment.created_at, finish)
  end

  def short_public_id(value, length: 12)
    value.to_s.delete("-").first(length)
  end

  def deployment_resource_size(revision)
    resources = revision&.readiness&.dig("resources")
    return "Not reported" unless resources.is_a?(Hash)

    cpu_millicores = resources["cpu_millicores"]
    memory_bytes = resources["memory_bytes"]
    return "Not reported" unless cpu_millicores.is_a?(Integer) && memory_bytes.is_a?(Integer)

    "#{cpu_millicores / 1000.0} vCPU · #{memory_bytes / 1.megabyte} MiB memory"
  end

  def transition_actor(transition, actors)
    return "System" unless transition.actor_type == "user"

    actor = actors[transition.actor_id]
    actor&.name.presence || actor&.email || "Former member"
  end
end
