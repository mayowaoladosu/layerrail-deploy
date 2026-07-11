require "rails_helper"

RSpec.describe "Health", type: :request do
  it "reports that the control plane is ready" do
    get "/health"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body).to eq("status" => "ok")
  end

  it "reports unavailability without exposing database details" do
    allow(ActiveRecord::Base.connection).to receive(:select_value)
      .and_raise(ActiveRecord::ConnectionNotEstablished)

    get "/health"

    expect(response).to have_http_status(:service_unavailable)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body).to eq("status" => "unavailable")
  end
end
