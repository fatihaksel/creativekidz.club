# frozen_string_literal: true

class InviteSerializer < ApplicationSerializer

  attributes :email, :updated_at, :redeemed_at, :expired, :user

  def include_email?
    options[:show_emails] && !object.redeemed?
  end

  def expired
    object.expired?
  end

  def user
    ser = InvitedUserSerializer.new(object.user, scope: scope, root: false)
    ser.invited_by = object.invited_by
    ser.as_json
  end

end
