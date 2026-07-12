module ApplicationHelper
  LEGACY_AVATAR_COLORS = %w[blue cyan emerald fuchsia green indigo orange pink purple red sky teal violet yellow].freeze

  def legacy_icon(name)
    raise ArgumentError, "invalid icon name" unless name.to_s.match?(/\A[a-z0-9-]+\z/)

    path = Rails.configuration.x.legacy_ui_root.join("templates/icons/#{name}.svg")
    raise ArgumentError, "unknown legacy icon" unless path.file?

    path.binread.html_safe
  end

  def legacy_avatar(item, size: :default, round: false)
    dimensions, text = {
      xs: [ "size-5 rounded text-xs font-semibold", "text-xs" ],
      sm: [ "size-6 rounded-md text-sm font-semibold", "text-sm" ],
      md: [ "size-10 rounded-lg text-xl font-medium", "text-xl" ],
      lg: [ "size-14 rounded-xl text-4xl font-medium", "text-4xl" ],
      default: [ "size-8 rounded-lg text-lg font-semibold", "text-lg" ]
    }.fetch(size)
    color = LEGACY_AVATAR_COLORS[Digest::SHA256.hexdigest(item.id.to_s).to_i(16) % LEGACY_AVATAR_COLORS.length]
    classes = [
      "flex items-center justify-center uppercase bg-gradient-to-tl border shrink-0",
      dimensions,
      "from-#{color}-100 to-#{color}-100/50 border-#{color}-200",
      "dark:from-#{color}-950/50 dark:to-#{color}-950 dark:border-#{color}-900 text-#{color}-500",
      ("!rounded-full" if round),
      text
    ].compact.join(" ")
    label = item.respond_to?(:name) ? item.name : item.to_s
    content_tag(:div, label.to_s.first.upcase, class: classes, aria: { hidden: true })
  end

  def legacy_status(deployment, compact: false)
    tone, label, icon, animation = case deployment.status
    when "ready", "promoted"
      [ "text-green-600 dark:text-green-500", "Succeeded", "circle-check", nil ]
    when "failed"
      [ "text-destructive", "Failed", "circle-x", nil ]
    when "canceled"
      [ "text-muted-foreground", "Canceled", "circle-x", nil ]
    when "superseded"
      [ "text-muted-foreground", "Skipped", "circle-arrow-right", nil ]
    else
      [ "text-muted-foreground", "In progress", "loader", "[&>svg]:animate-spin" ]
    end
    content_tag(:span,
      safe_join([ legacy_icon(icon), (label unless compact) ].compact, ""),
      class: "#{tone} [&>svg]:#{tone} [&>svg]:size-4 flex items-center gap-x-2 #{animation}",
      data: { tooltip: label })
  end

  def legacy_environment_color(environment)
    {
      "production" => "green",
      "staging" => "amber",
      "custom" => "blue"
    }.fetch(environment.kind, "blue")
  end

  def legacy_deployment_path(deployment)
    project_deployment_path(
      deployment.organization.slug,
      deployment.project.slug,
      deployment
    )
  end

  def legacy_deployments_path(project, **query)
    project_deployments_path(project.organization.slug, project.slug, **query)
  end

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
