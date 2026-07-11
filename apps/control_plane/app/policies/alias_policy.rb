class AliasPolicy < ApplicationPolicy
  def promote?
    member_of_selected_organization? && context.role?(:owner, :admin)
  end

  def show?
    member_of_selected_organization?
  end
end
