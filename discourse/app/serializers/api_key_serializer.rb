# frozen_string_literal: true

class ApiKeySerializer < ApplicationSerializer

  attributes :id,
             :key,
             :truncated_key,
             :description,
             :last_used_at,
             :created_at,
             :updated_at,
             :revoked_at

  has_one :user, serializer: BasicUserSerializer, embed: :objects

  def include_user_id?
    !object.user_id.nil?
  end

  def include_key?
    # Only available when first created. Not stored in db
    object.key_available?
  end
end
