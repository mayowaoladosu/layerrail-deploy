class ProjectPolicy < ApplicationPolicy
  def create?
    member_of_selected_organization? && context.role?(:owner, :admin)
  end

  def show?
    member_of_selected_organization?
  end

  def update?
    show? && context.role?(:owner, :admin)
  end

  def request_deletion?
    show? && context.role?(:owner)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless context&.member?

      scope.where(organization_id: context.organization.id)
    end
  end
end
