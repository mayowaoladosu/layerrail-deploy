class GitInstallationPolicy < ApplicationPolicy
  def create?
    member_of_selected_organization? && context.role?(:owner, :admin)
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
