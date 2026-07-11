class OrganizationPolicy < ApplicationPolicy
  def show?
    member_of_selected_organization?
  end

  def update?
    show? && context.role?(:owner, :admin)
  end

  def manage_members?
    update?
  end

  def destroy?
    show? && context.role?(:owner)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless context&.member?

      scope.where(id: context.organization.id)
    end
  end
end
