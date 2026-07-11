class ConfigurationVersionPolicy < ApplicationPolicy
  def create?
    member_of_selected_organization? && context.role?(:owner, :admin)
  end

  def show?
    member_of_selected_organization?
  end

  def reveal?
    show? && context.role?(:owner, :admin)
  end
end
