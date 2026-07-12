class DeploymentPolicy < ApplicationPolicy
  def index?
    context&.member?
  end

  def create?
    system_of_selected_organization? || (member_of_selected_organization? && context.role?(:owner, :admin))
  end

  def show?
    member_of_selected_organization?
  end

  def transition?
    create?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless context&.member?

      scope.where(organization_id: context.organization.id)
    end
  end
end
