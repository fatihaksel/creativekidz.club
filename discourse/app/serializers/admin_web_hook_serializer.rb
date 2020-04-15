# frozen_string_literal: true

class AdminWebHookSerializer < ApplicationSerializer
  attributes :id,
             :payload_url,
             :content_type,
             :last_delivery_status,
             :secret,
             :wildcard_web_hook,
             :verify_certificate,
             :active,
             :web_hook_event_types

  has_many :categories, serializer: BasicCategorySerializer, embed: :ids, include: false
  has_many :tags, key: :tag_names, serializer: TagSerializer, embed: :ids, embed_key: :name, include: false
  has_many :groups, serializer: BasicGroupSerializer, embed: :ids, include: false

  def web_hook_event_types
    ActiveModel::ArraySerializer.new(object.web_hook_event_types).as_json
  end

  def last_delivery_status
    object.active ? object.last_delivery_status : WebHook.last_delivery_statuses[:disabled]
  end
end
