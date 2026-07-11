class RepositoryConnectionPolicy < ApplicationPolicy
  def create?
    member_of_selected_organization? &&
      context.role?(:owner, :admin) &&
      record.git_installation&.organization_id == context.organization.id &&
      record.service&.organization_id == context.organization.id
  end

  def show?
    member_of_selected_organization?
  end

  def update?
    create?
  end

  def disconnect?
    show? && context.role?(:owner)
  end
end
