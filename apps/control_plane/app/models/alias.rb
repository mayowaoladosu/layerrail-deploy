class Alias < ApplicationRecord
  TYPES = %w[environment branch].index_with(&:itself).freeze

  belongs_to :organization
  belongs_to :project
  belongs_to :service
  belongs_to :environment
  belongs_to :current_revision, class_name: "Revision"
  belongs_to :previous_revision, class_name: "Revision", optional: true

  enum :alias_type, TYPES, prefix: true, validate: true

  attr_readonly :organization_id,
    :project_id,
    :service_id,
    :environment_id,
    :alias_type,
    :name

  validates :name, presence: true, length: { maximum: 255 }, uniqueness: { scope: [ :service_id, :alias_type ] }
  validate :name_is_normalized
  validate :ownership_matches
  validate :revision_status_keys_match
  validate :revisions_are_ready

  private

  def name_is_normalized
    errors.add(:name, "must be normalized") unless name == name.to_s.strip && name.present?
  end

  def ownership_matches
    return unless organization && project && service && environment

    unless project.organization_id == organization_id &&
        service.project_id == project_id &&
        environment.project_id == project_id
      errors.add(:organization, "must own the alias resources")
    end
  end

  def revision_status_keys_match
    errors.add(:current_revision_status, "must be ready") unless current_revision_status == "ready"

    if previous_revision_id
      errors.add(:previous_revision_status, "must be ready") unless previous_revision_status == "ready"
    elsif previous_revision_status
      errors.add(:previous_revision_status, "must be absent without a previous revision")
    end
  end

  def revisions_are_ready
    if previous_revision_id && previous_revision_id == current_revision_id
      errors.add(:previous_revision, "must differ from the current revision")
    end

    [ current_revision, previous_revision ].compact.each do |revision|
      unless revision.status == "ready" &&
          revision.organization_id == organization_id &&
          revision.service_id == service_id &&
          revision.environment_id == environment_id
        errors.add(:current_revision, "must be a ready revision for the alias resources")
      end
    end
  end
end
