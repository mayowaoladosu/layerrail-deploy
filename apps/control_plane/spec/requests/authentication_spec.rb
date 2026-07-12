require "rails_helper"

RSpec.describe "Rodauth browser authentication", type: :request do
  def github_configured?
    ENV["GITHUB_APP_CLIENT_ID"].present? && ENV["GITHUB_APP_CLIENT_SECRET"].present?
  end

  it "renders the legacy authentication design and redirects unauthenticated requests" do
    get "/"
    expect(response).to redirect_to("/auth/login")

    get "/auth/login"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(
      "Sign in to LayerRail Deploy",
      "Continue with email",
      "legacy-assets/styles.css",
      "sticky top-0 bg-background z-20 border-b px-8"
    )
    expect(response.body.include?("Continue with GitHub")).to eq(github_configured?)
    expect(response.body).not_to include("auth-brand", "Ship code without surrendering control")
  end

  it "only exposes provider login when Rodauth has matching credentials" do
    post "/auth/github"

    if github_configured?
      expect(response).to have_http_status(:redirect)
      location = URI(response.location)
      expect(location.host).to eq("github.com")
      expect(location.path).to eq("/login/oauth/authorize")
    else
      expect(response).to have_http_status(:not_found)
    end
  end

  it "uses one Rodauth email link to bootstrap and authenticate the first owner" do
    expect do
      post "/auth/login", params: { email: "Browser.User@Example.com" }
    end.to change(User, :count).by(1)
      .and change(ActionMailer::Base.deliveries, :count).by(1)

    expect(response).to redirect_to(auth_check_email_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Check your email")

    key = last_email_auth_key
    get last_email_auth_path

    expect(response).to redirect_to("/auth/verify")
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Finish signing in", "Continue with email")

    expect do
      post "/auth/verify"
    end.to change(Organization, :count).by(1)
      .and change(Membership, :count).by(1)
      .and change(RodauthLoginClaim, :count).by(1)

    expect(response).to redirect_to(root_path)
    set_cookie = Array(response.headers.fetch("Set-Cookie")).join("; ").downcase
    expect(set_cookie).to include("_lrail_control_plane_session=", "httponly", "samesite=lax")
    expect(set_cookie).not_to include(key.downcase)

    follow_redirect!
    user = User.sole
    organization = user.organizations.sole
    expect(response).to redirect_to(team_path(organization.slug))
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Browser User Organization", "Deploy your first project.")
    expect(user).to have_attributes(
      email: "browser.user@example.com",
      authentication_state: "active"
    )
    expect(organization.memberships.sole).to have_attributes(user:, role: "owner")
    expect(RodauthLoginClaim.sole.token_digest).to eq(Digest::SHA256.hexdigest(key))
  end

  it "revokes its active Rodauth session on logout" do
    owner = User.create!(email: "browser-logout@example.com", name: "Browser Logout")
    Organizations::Create.call(principal: owner, name: "Browser Logout Organization")
    sign_in_with_rodauth(owner)

    expect(ApplicationRecord.connection.select_value(
      "SELECT COUNT(*) FROM user_active_session_keys WHERE user_id = '#{owner.id}'"
    ).to_i).to eq(1)

    post "/auth/logout"
    expect(response).to redirect_to("/auth/login")
    expect(ApplicationRecord.connection.select_value(
      "SELECT COUNT(*) FROM user_active_session_keys WHERE user_id = '#{owner.id}'"
    ).to_i).to eq(0)

    get root_path
    expect(response).to redirect_to("/auth/login")
  end

  it "rejects invalid and replayed links without creating another session" do
    owner = User.create!(email: "browser-replay@example.com", name: "Browser Replay")
    Organizations::Create.call(principal: owner, name: "Browser Replay Organization")

    post "/auth/login", params: { email: owner.email }
    used_path = last_email_auth_path
    get used_path
    follow_redirect!
    post "/auth/verify"
    post "/auth/logout"

    get used_path
    expect(response).to redirect_to("/auth/verify")
    follow_redirect!
    expect(response).to redirect_to("/auth/login")
    follow_redirect!
    expect(response.body).to include("invalid or has expired")

    get "/auth/verify", params: { key: "invalid" }
    expect(response).to redirect_to("/auth/verify")
    follow_redirect!
    expect(response).to redirect_to("/auth/login")
    expect(RodauthLoginClaim.count).to eq(1)
  end
end
