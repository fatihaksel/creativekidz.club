# frozen_string_literal: true

class TagsController < ::ApplicationController
  include TopicListResponder
  include TopicQueryParams

  before_action :ensure_tags_enabled
  before_action :ensure_visible, only: [:show, :info]

  requires_login except: [
    :index,
    :show,
    :tag_feed,
    :search,
    :check_hashtag,
    :info,
    Discourse.anonymous_filters.map { |f| :"show_#{f}" }
  ].flatten

  skip_before_action :check_xhr, only: [:tag_feed, :show, :index]

  before_action :set_category_from_params, except: [:index, :update, :destroy,
    :tag_feed, :search, :notifications, :update_notifications, :personal_messages, :info]

  before_action :fetch_tag, only: [:info, :create_synonyms, :destroy_synonym]

  def index
    @description_meta = I18n.t("tags.title")
    @title = @description_meta

    show_all_tags = guardian.can_admin_tags? && guardian.is_admin?

    if SiteSetting.tags_listed_by_group
      ungrouped_tags = Tag.where("tags.id NOT IN (SELECT tag_id FROM tag_group_memberships)")
      ungrouped_tags = ungrouped_tags.where("tags.topic_count > 0") unless show_all_tags

      grouped_tag_counts = TagGroup.visible(guardian).order('name ASC').includes(:tags).map do |tag_group|
        { id: tag_group.id, name: tag_group.name, tags: self.class.tag_counts_json(tag_group.tags.where(target_tag_id: nil)) }
      end

      @tags = self.class.tag_counts_json(ungrouped_tags)
      @extras = { tag_groups: grouped_tag_counts }
    else
      tags = show_all_tags ? Tag.all : Tag.where("tags.topic_count > 0")
      unrestricted_tags = DiscourseTagging.filter_visible(tags.where(target_tag_id: nil), guardian)

      categories = Category.where("id IN (SELECT category_id FROM category_tags)")
        .where("id IN (?)", guardian.allowed_category_ids)
        .includes(:tags)

      category_tag_counts = categories.map do |c|
        { id: c.id, tags: self.class.tag_counts_json(c.tags.where(target_tag_id: nil)) }
      end

      @tags = self.class.tag_counts_json(unrestricted_tags)
      @extras = { categories: category_tag_counts }
    end

    respond_to do |format|

      format.html do
        render :index
      end

      format.json do
        render json: {
          tags: @tags,
          extras: @extras
        }
      end
    end
  end

  Discourse.filters.each do |filter|
    define_method("show_#{filter}") do
      @tag_id = params[:tag_id].force_encoding("UTF-8")
      @additional_tags = params[:additional_tag_ids].to_s.split('/').map { |t| t.force_encoding("UTF-8") }

      list_opts = build_topic_list_options

      @list = TopicQuery.new(current_user, list_opts).public_send("list_#{filter}")

      @list.draft_key = Draft::NEW_TOPIC
      @list.draft_sequence = DraftSequence.current(current_user, Draft::NEW_TOPIC)
      @list.draft = Draft.get(current_user, @list.draft_key, @list.draft_sequence) if current_user

      @list.more_topics_url = construct_url_with(:next, list_opts)
      @list.prev_topics_url = construct_url_with(:prev, list_opts)
      @rss = "tag"
      @description_meta = I18n.t("rss_by_tag", tag: tag_params.join(' & '))
      @title = @description_meta

      path_name = url_method(params.slice(:category, :parent_category))
      canonical_url "#{Discourse.base_url_no_prefix}#{public_send(path_name, *(params.slice(:parent_category, :category, :tag_id).values.map { |t| t.force_encoding("UTF-8") }))}"

      if @list.topics.size == 0 && params[:tag_id] != 'none' && !Tag.where_name(@tag_id).exists?
        raise Discourse::NotFound.new("tag not found", check_permalinks: true)
      else
        respond_with_list(@list)
      end
    end
  end

  def show
    show_latest
  end

  def info
    render_serialized(
      @tag,
      DetailedTagSerializer,
      rest_serializer: true,
      root: :tag_info
    )
  end

  def update
    guardian.ensure_can_admin_tags!

    tag = Tag.find_by_name(params[:tag_id])
    raise Discourse::NotFound if tag.nil?

    new_tag_name = DiscourseTagging.clean_tag(params[:tag][:id])
    tag.name = new_tag_name
    if tag.save
      StaffActionLogger.new(current_user).log_custom('renamed_tag', previous_value: params[:tag_id], new_value: new_tag_name)
      render json: { tag: { id: new_tag_name } }
    else
      render_json_error tag.errors.full_messages
    end
  end

  def upload
    require 'csv'

    guardian.ensure_can_admin_tags!

    file = params[:file] || params[:files].first

    hijack do
      begin
        Tag.transaction do
          CSV.foreach(file.tempfile) do |row|
            raise Discourse::InvalidParameters.new(I18n.t("tags.upload_row_too_long")) if row.length > 2

            tag_name = DiscourseTagging.clean_tag(row[0])
            tag_group_name = row[1] || nil

            tag = Tag.find_by_name(tag_name) || Tag.create!(name: tag_name)

            if tag_group_name
              tag_group = TagGroup.find_by(name: tag_group_name) || TagGroup.create!(name: tag_group_name)
              tag.tag_groups << tag_group unless tag.tag_groups.include?(tag_group)
            end
          end
        end
        render json: success_json
      rescue Discourse::InvalidParameters => e
        render json: failed_json.merge(errors: [e.message]), status: 422
      end
    end
  end

  def list_unused
    guardian.ensure_can_admin_tags!
    render json: { tags: Tag.unused.pluck(:name) }
  end

  def destroy_unused
    guardian.ensure_can_admin_tags!
    tags = Tag.unused
    StaffActionLogger.new(current_user).log_custom('deleted_unused_tags', tags: tags.pluck(:name))
    tags.destroy_all
    render json: success_json
  end

  def destroy
    guardian.ensure_can_admin_tags!
    tag_name = params[:tag_id]
    tag = Tag.find_by_name(tag_name)
    raise Discourse::NotFound if tag.nil?

    TopicCustomField.transaction do
      tag.destroy
      StaffActionLogger.new(current_user).log_custom('deleted_tag', subject: tag_name)
    end
    render json: success_json
  end

  def tag_feed
    discourse_expires_in 1.minute

    tag_id = params[:tag_id]
    @link = "#{Discourse.base_url}/tag/#{tag_id}"
    @description = I18n.t("rss_by_tag", tag: tag_id)
    @title = "#{SiteSetting.title} - #{@description}"
    @atom_link = "#{Discourse.base_url}/tag/#{tag_id}.rss"

    query = TopicQuery.new(current_user, tags: [tag_id])
    latest_results = query.latest_results
    @topic_list = query.create_list(:by_tag, {}, latest_results)

    render 'list/list', formats: [:rss]
  end

  def search
    filter_params = {
      for_input: params[:filterForInput],
      selected_tags: params[:selected_tags],
      limit: params[:limit],
      exclude_synonyms: params[:excludeSynonyms],
      exclude_has_synonyms: params[:excludeHasSynonyms]
    }

    if params[:categoryId]
      filter_params[:category] = Category.find_by_id(params[:categoryId])
    end

    if !params[:q].blank?
      clean_name = DiscourseTagging.clean_tag(params[:q])
      filter_params[:term] = clean_name
      filter_params[:order_search_results] = true
    else
      filter_params[:order_popularity] = true
    end

    tags_with_counts = DiscourseTagging.filter_allowed_tags(
      guardian,
      filter_params
    )

    tags = self.class.tag_counts_json(tags_with_counts)

    json_response = { results: tags }

    if clean_name && !tags.find { |h| h[:id].downcase == clean_name.downcase } && tag = Tag.where_name(clean_name).first
      # filter_allowed_tags determined that the tag entered is not allowed
      json_response[:forbidden] = params[:q]

      if filter_params[:exclude_synonyms] && tag.synonym?
        json_response[:forbidden_message] = I18n.t("tags.forbidden.synonym", tag_name: tag.target_tag.name)
      elsif filter_params[:exclude_has_synonyms] && tag.synonyms.exists?
        json_response[:forbidden_message] = I18n.t("tags.forbidden.has_synonyms", tag_name: tag.name)
      else
        category_names = tag.categories.where(id: guardian.allowed_category_ids).pluck(:name)
        category_names += Category.joins(tag_groups: :tags).where(id: guardian.allowed_category_ids, "tags.id": tag.id).pluck(:name)

        if category_names.present?
          category_names.uniq!
          json_response[:forbidden_message] = I18n.t(
            "tags.forbidden.restricted_to",
            count: category_names.count,
            tag_name: tag.name,
            category_names: category_names.join(", ")
          )
        else
          json_response[:forbidden_message] = I18n.t("tags.forbidden.in_this_category", tag_name: tag.name)
        end
      end
    end

    render json: json_response
  end

  def notifications
    tag = Tag.where_name(params[:tag_id]).first
    raise Discourse::NotFound unless tag
    level = tag.tag_users.where(user: current_user).first.try(:notification_level) || TagUser.notification_levels[:regular]
    render json: { tag_notification: { id: tag.name, notification_level: level.to_i } }
  end

  def update_notifications
    tag = Tag.find_by_name(params[:tag_id])
    raise Discourse::NotFound unless tag
    level = params[:tag_notification][:notification_level].to_i
    TagUser.change(current_user.id, tag.id, level)
    render json: { notification_level: level }
  end

  def check_hashtag
    valid_tags = Tag.where_name(params[:tag_values]).map do |tag|
      { value: tag.name, url: tag.full_url }
    end.compact

    render json: { valid: valid_tags }
  end

  def personal_messages
    guardian.ensure_can_tag_pms!
    allowed_user = fetch_user_from_params
    raise Discourse::NotFound if allowed_user.blank?
    raise Discourse::NotFound if current_user.id != allowed_user.id && !@guardian.is_admin?
    pm_tags = Tag.pm_tags(guardian: guardian, allowed_user: allowed_user)

    render json: { tags: pm_tags }
  end

  def create_synonyms
    guardian.ensure_can_admin_tags!
    value = DiscourseTagging.add_or_create_synonyms_by_name(@tag, params[:synonyms])
    if value.is_a?(Array)
      render json: failed_json.merge(
        failed_tags: value.inject({}) { |h, t| h[t.name] = t.errors.full_messages.first; h }
      )
    else
      render json: success_json
    end
  end

  def destroy_synonym
    guardian.ensure_can_admin_tags!
    synonym = Tag.where_name(params[:synonym_id]).first
    raise Discourse::NotFound unless synonym
    if synonym.target_tag == @tag
      synonym.update!(target_tag: nil)
      render json: success_json
    else
      render json: failed_json, status: 400
    end
  end

  private

  def fetch_tag
    @tag = Tag.find_by_name(params[:tag_id].force_encoding("UTF-8"))
    raise Discourse::NotFound unless @tag
  end

  def ensure_tags_enabled
    raise Discourse::NotFound unless SiteSetting.tagging_enabled?
  end

  def ensure_visible
    raise Discourse::NotFound if DiscourseTagging.hidden_tag_names(guardian).include?(params[:tag_id])
  end

  def self.tag_counts_json(tags)
    target_tags = Tag.where(id: tags.map(&:target_tag_id).compact.uniq).select(:id, :name)
    tags.map do |t|
      {
        id: t.name,
        text: t.name,
        count: t.topic_count,
        pm_count: t.pm_topic_count,
        target_tag: t.target_tag_id ? target_tags.find { |x| x.id == t.target_tag_id }&.name : nil
      }
    end
  end

  def set_category_from_params
    if request.path_parameters.include?(:category_slug_path_with_id)
      parts = params[:category_slug_path_with_id].split('/')

      if !parts.empty? && parts.last =~ /\A\d+\Z/
        id = parts.pop.to_i
      end
      slug_path = parts unless parts.empty?

      if id.present?
        @filter_on_category = Category.find_by_id(id)
      elsif slug_path.present?
        if (1..2).include?(slug_path.size)
          @filter_on_category = Category.find_by_slug(*slug_path.reverse)
        end

        # Legacy paths
        if @filter_on_category.nil? && parts.last =~ /\A\d+-category/
          @filter_on_category = Category.find_by_id(parts.last.to_i)
        end
      end
    else
      slug_or_id = params[:category]
      return true if slug_or_id.nil?

      @filter_on_category = Category.query_category(slug_or_id, nil)
    end

    category_redirect_or_not_found && (return) if !@filter_on_category

    guardian.ensure_can_see!(@filter_on_category)
  end

  def page_params
    route_params = { format: 'json' }

    if @filter_on_category
      if request.path_parameters.include?(:category_slug_path_with_id)
        slug_path = @filter_on_category.slug_path

        route_params[:category_slug_path_with_id] =
          (slug_path + [@filter_on_category.id.to_s]).join("/")
      else
        route_params[:category] = @filter_on_category.slug_for_url
      end
    end

    route_params
  end

  def next_page_params
    page_params.merge(page: params[:page].to_i + 1)
  end

  def prev_page_params
    pg = params[:page].to_i
    if pg > 1
      page_params.merge(page: pg - 1)
    else
      page_params.merge(page: nil)
    end
  end

  def url_method(opts = {})
    if opts[:parent_category] && opts[:category]
      "tag_parent_category_category_#{action_name}_path"
    elsif opts[:category]
      "tag_category_#{action_name}_path"
    else
      "tag_#{action_name}_path"
    end
  end

  def construct_url_with(action, opts)
    method = url_method(opts)

    page_params =
      case action
      when :prev
        prev_page_params
      when :next
        next_page_params
      else
        raise "unreachable"
      end

    if page_params.include?(:category_slug_path_with_id)
      opts = opts.dup
      opts.delete(:category)
    end

    begin
      url = public_send(method, opts.merge(page_params))
    rescue ActionController::UrlGenerationError
      raise Discourse::NotFound
    end

    url.sub('.json?', '?')
  end

  def build_topic_list_options
    options = super.merge(
      page: params[:page],
      topic_ids: param_to_integer_list(:topic_ids),
      category: @filter_on_category ? @filter_on_category.id : params[:category],
      order: params[:order],
      ascending: params[:ascending],
      min_posts: params[:min_posts],
      max_posts: params[:max_posts],
      status: params[:status],
      filter: params[:filter],
      state: params[:state],
      search: params[:search],
      q: params[:q]
    )
    options[:no_subcategories] = true if params[:no_subcategories] == 'true'

    if params[:tag_id] == 'none'
      options[:no_tags] = true
    else
      options[:tags] = tag_params
      options[:match_all_tags] = true
    end

    options
  end

  def category_redirect_or_not_found
    # automatic redirects for renamed categories
    url = params[:parent_category] ? "c/#{params[:parent_category]}/#{params[:category]}" : "c/#{params[:category]}"
    permalink = Permalink.find_by_url(url)

    if permalink.present? && permalink.category_id
      redirect_to "#{Discourse::base_uri}/tags#{permalink.target_url}/#{params[:tag_id]}", status: :moved_permanently
    else
      # redirect to 404
      raise Discourse::NotFound
    end
  end

  def tag_params
    [@tag_id].concat(Array(@additional_tags))
  end
end
