class RepositoryConnection < ApplicationRecord
  STATUSES = {
    active: "active",
    removed: "removed",
    disconnected: "disconnected"
  }.freeze

  belongs_to :organization
  belongs_to :git_installation
  belongs_to :project
  belongs_to :service

  enum :status, STATUSES, prefix: true, validate: true

  validates :service_id, uniqueness: true
  validates :provider_repository_id,
    presence: true,
    length: { maximum: 255 },
    uniqueness: { scope: :git_installation_id }
  validates :owner, :name, :full_name, :default_branch, presence: true
  validates :owner, :name, :full_name, :default_branch, length: { maximum: 255 }
  validate :organization_ownership_matches

  private

  def organization_ownership_matches
    return unless organization && git_installation && service

    unless git_installation.organization_id == organization_id &&
        project.organization_id == organization_id &&
        service.project_id == project_id
      errors.add(:organization, "must own the installation and service")
    end
  end
end
