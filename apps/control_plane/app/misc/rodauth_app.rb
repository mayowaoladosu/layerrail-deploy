class RodauthApp < Rodauth::Rails::App
  configure RodauthMain

  route do |request|
    rodauth.check_active_session
    request.rodauth
  end
end
