require "rails_helper"

RSpec.describe "Browser authentication", type: :request do
  it "renders login and redirects unauthenticated home requests" do
    get "/"
    expect(response).to redirect_to(auth_login_path)

    get auth_login_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Sign in to your control plane")
  end

  it "uses one email challenge to create a secure web session" do
    expect do
      post auth_login_path, params: { email: "Browser.User@Example.com" }
    end.to change(LoginChallenge, :count).by(1)
      .and change(ActionMailer::Base.deliveries, :count).by(1)

    expect(response).to have_http_status(:accepted)
    expect(response.body).to include("Check your email")
    challenge = LoginChallenge.sole

    get auth_verify_path(token: challenge.token)

    expect(response).to redirect_to(auth_confirm_path)
    expect(challenge.reload.consumed_at).to be_nil
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Finish signing in")

    post auth_verify_path

    expect(response).to redirect_to(root_path)
    set_cookie = Array(response.headers.fetch("Set-Cookie")).join("; ")
    expect(set_cookie).to include("#{Authentication::Middleware::COOKIE_NAME}=")
    expect(set_cookie.downcase).to include("httponly", "samesite=lax")
    expect(response.headers.fetch("Set-Cookie")).not_to include(challenge.token)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Welcome, Browser User")
    expect(challenge.reload).to have_attributes(consumed_at: be_present, token: nil)
    expect(AuthenticationSession.sole.kind).to eq("web")
    expect(Organization.sole.memberships.sole.role).to eq("owner")
  end

  it "revokes the current web session on logout" do
    owner = User.create!(email: "browser-logout@example.com", name: "Browser Logout")
    Organizations::Create.call(principal: owner, name: "Browser Logout Organization")
    issued = Authentication::Sessions.issue(user: owner, kind: :web, ip: nil, user_agent: nil)
    cookies[Authentication::Middleware::COOKIE_NAME] = issued.token

    get root_path
    expect(response).to have_http_status(:ok)

    post auth_logout_path
    expect(response).to redirect_to(auth_login_path)
    expect(issued.session.reload.revoked_at).to be_present

    get root_path
    expect(response).to redirect_to(auth_login_path)
  end

  it "rejects an invalid or replayed browser link without creating a session" do
    get auth_verify_path(token: "invalid")
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("invalid or has expired")
    expect(AuthenticationSession).not_to exist
  end
end
