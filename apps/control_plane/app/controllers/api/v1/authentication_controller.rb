module Api
  module V1
    class AuthenticationController < BaseController
      skip_before_action :authenticate_principal!, only: %i[challenge create]
      skip_before_action :select_organization!

      rescue_from Authentication::Challenges::InvalidEmail, with: :render_invalid_email
      rescue_from Authentication::Challenges::InvalidChallenge, with: :render_invalid_challenge

      def challenge
        issued = Authentication::Challenges.issue(
          email: params[:email],
          ip: request.remote_ip
        )
        if issued.challenge
          AuthenticationMailer.with(challenge: issued.challenge).login_link.deliver_now
          Authentication::Challenges.mark_delivered(issued.challenge)
        end

        render json: {
          message: "If the address can sign in, a one-time link has been sent",
          expires_in: Authentication::Challenges::DEFAULT_TTL.to_i
        }, status: :accepted
      end

      def create
        result = Authentication::Challenges.complete(
          token: params[:token],
          session_kind: :api,
          ip: request.remote_ip,
          user_agent: request.user_agent
        )

        render json: serialize_authentication(result), status: :created
      end

      def destroy
        authentication_session = current_authentication_session
        return render_error(:unauthorized, "unauthenticated", "Authentication is required") unless authentication_session

        Authentication::Sessions.revoke(
          session: authentication_session,
          reason: "user_logout"
        )
        head :no_content
      end

      def show
        render json: {
          user: serialize_user(current_principal),
          organizations: current_principal.organizations.order(:created_at, :id).map { |organization| serialize_organization(organization) }
        }, status: :ok
      end

      private

      def serialize_authentication(result)
        {
          access_token: result.token,
          token_type: "Bearer",
          expires_at: result.session.expires_at.iso8601(6),
          user: serialize_user(result.user),
          organization: result.organization ? serialize_organization(result.organization) : nil
        }
      end

      def serialize_user(user)
        {
          id: user.id,
          email: user.email,
          name: user.name,
          created_at: user.created_at.iso8601(6)
        }
      end

      def serialize_organization(organization)
        {
          id: organization.id,
          name: organization.name,
          created_at: organization.created_at.iso8601(6)
        }
      end

      def render_invalid_email
        render_validation_error(:email, "is invalid")
      end

      def render_invalid_challenge
        render_error(
          :unprocessable_content,
          "invalid_challenge",
          "The login link is invalid or expired"
        )
      end
    end
  end
end
