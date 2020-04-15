# frozen_string_literal: true

class UserApiKeysController < ApplicationController

  layout 'no_ember'

  requires_login only: [:create, :create_otp, :revoke, :undo_revoke]
  skip_before_action :redirect_to_login_if_required, only: [:new, :otp]
  skip_before_action :check_xhr, :preload_json

  AUTH_API_VERSION ||= 4

  def new

    if request.head?
      head :ok, auth_api_version: AUTH_API_VERSION
      return
    end

    require_params
    validate_params

    unless current_user
      cookies[:destination_url] = request.fullpath

      if SiteSetting.enable_sso?
        redirect_to path('/session/sso')
      else
        redirect_to path('/login')
      end
      return
    end

    unless meets_tl?
      @no_trust_level = true
      return
    end

    @application_name = params[:application_name]
    @public_key = params[:public_key]
    @nonce = params[:nonce]
    @client_id = params[:client_id]
    @auth_redirect = params[:auth_redirect]
    @push_url = params[:push_url]
    @localized_scopes = params[:scopes].split(",").map { |s| I18n.t("user_api_key.scopes.#{s}") }
    @scopes = params[:scopes]

  rescue Discourse::InvalidAccess
    @generic_error = true
  end

  def create

    require_params

    if params.key?(:auth_redirect)
      raise Discourse::InvalidAccess if UserApiKey.invalid_auth_redirect?(params[:auth_redirect])
    end

    raise Discourse::InvalidAccess unless meets_tl?

    validate_params
    @application_name = params[:application_name]
    scopes = params[:scopes].split(",")

    # destroy any old keys we had
    UserApiKey.where(user_id: current_user.id, client_id: params[:client_id]).destroy_all

    key = UserApiKey.create!(
      application_name: @application_name,
      client_id: params[:client_id],
      user_id: current_user.id,
      push_url: params[:push_url],
      scopes: scopes
    )

    # we keep the payload short so it encrypts easily with public key
    # it is often restricted to 128 chars
    @payload = {
      key: key.key,
      nonce: params[:nonce],
      push: key.has_push?,
      api: AUTH_API_VERSION
    }.to_json

    public_key = OpenSSL::PKey::RSA.new(params[:public_key])
    @payload = Base64.encode64(public_key.public_encrypt(@payload))

    if scopes.include?("one_time_password")
      # encrypt one_time_password separately to bypass 128 chars encryption limit
      otp_payload = one_time_password(public_key, current_user.username)
    end

    if params[:auth_redirect]
      uri = URI.parse(params[:auth_redirect])
      query_attributes = [uri.query, "payload=#{CGI.escape(@payload)}"]
      query_attributes << "oneTimePassword=#{CGI.escape(otp_payload)}" if scopes.include?("one_time_password")
      uri.query = query_attributes.compact.join('&')

      redirect_to(uri.to_s)
    else
      respond_to do |format|
        format.html { render :show }
        format.json do
          instructions = I18n.t("user_api_key.instructions", application_name: @application_name)
          render json: { payload: @payload, instructions: instructions }
        end
      end
    end
  end

  def otp
    require_params_otp

    unless current_user
      cookies[:destination_url] = request.fullpath

      if SiteSetting.enable_sso?
        redirect_to path('/session/sso')
      else
        redirect_to path('/login')
      end
      return
    end

    @application_name = params[:application_name]
    @public_key = params[:public_key]
    @auth_redirect = params[:auth_redirect]
  end

  def create_otp
    require_params_otp

    raise Discourse::InvalidAccess if UserApiKey.invalid_auth_redirect?(params[:auth_redirect])
    raise Discourse::InvalidAccess unless meets_tl?

    public_key = OpenSSL::PKey::RSA.new(params[:public_key])
    otp_payload = one_time_password(public_key, current_user.username)

    redirect_path = "#{params[:auth_redirect]}?oneTimePassword=#{CGI.escape(otp_payload)}"
    redirect_to(redirect_path)
  end

  def revoke
    revoke_key = find_key if params[:id]

    if current_key = request.env['HTTP_USER_API_KEY']
      request_key = UserApiKey.with_key(current_key).first
      revoke_key ||= request_key
      if request_key && request_key.id != revoke_key.id && !request_key.scopes.include?("write")
        raise Discourse::InvalidAccess
      end
    end

    raise Discourse::NotFound unless revoke_key

    revoke_key.update_columns(revoked_at: Time.zone.now)

    render json: success_json
  end

  def undo_revoke
    find_key.update_columns(revoked_at: nil)
    render json: success_json
  end

  def find_key
    key = UserApiKey.find(params[:id])
    raise Discourse::InvalidAccess unless current_user.admin || key.user_id == current_user.id
    key
  end

  def require_params
    [
     :public_key,
     :nonce,
     :scopes,
     :client_id,
     :application_name
    ].each { |p| params.require(p) }
  end

  def validate_params
    requested_scopes = Set.new(params[:scopes].split(","))
    raise Discourse::InvalidAccess unless UserApiKey.allowed_scopes.superset?(requested_scopes)

    # our pk has got to parse
    OpenSSL::PKey::RSA.new(params[:public_key])
  end

  def require_params_otp
    [
     :public_key,
     :auth_redirect,
     :application_name
    ].each { |p| params.require(p) }
  end

  def meets_tl?
    current_user.staff? || current_user.trust_level >= SiteSetting.min_trust_level_for_user_api_key
  end

  def one_time_password(public_key, username)
    raise Discourse::InvalidAccess unless UserApiKey.allowed_scopes.superset?(Set.new(["one_time_password"]))

    otp = SecureRandom.hex
    Discourse.redis.setex "otp_#{otp}", 10.minutes, username

    Base64.encode64(public_key.public_encrypt(otp))
  end
end
