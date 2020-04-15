# frozen_string_literal: true

class CategoriesController < ApplicationController

  requires_login except: [:index, :categories_and_latest, :categories_and_top, :show, :redirect, :find_by_slug]

  before_action :fetch_category, only: [:show, :update, :destroy]
  before_action :initialize_staff_action_logger, only: [:create, :update, :destroy]
  skip_before_action :check_xhr, only: [:index, :categories_and_latest, :categories_and_top, :redirect]

  SYMMETRICAL_CATEGORIES_TO_TOPICS_FACTOR = 1.5
  MIN_CATEGORIES_TOPICS = 5

  def redirect
    return if handle_permalink("/category/#{params[:path]}")
    redirect_to path("/c/#{params[:path]}")
  end

  def index
    discourse_expires_in 1.minute

    @description = SiteSetting.site_description

    parent_category = Category.find_by_slug(params[:parent_category_id]) || Category.find_by(id: params[:parent_category_id].to_i)

    category_options = {
      is_homepage: current_homepage == "categories".freeze,
      parent_category_id: params[:parent_category_id],
      include_topics: include_topics(parent_category)
    }

    @category_list = CategoryList.new(guardian, category_options)
    @category_list.draft_key = Draft::NEW_TOPIC
    @category_list.draft_sequence = DraftSequence.current(
      current_user,
      Draft::NEW_TOPIC
    )
    @category_list.draft = Draft.get(current_user, Draft::NEW_TOPIC, @category_list.draft_sequence) if current_user

    if category_options[:is_homepage] && SiteSetting.short_site_description.present?
      @title = "#{SiteSetting.title} - #{SiteSetting.short_site_description}"
    elsif !category_options[:is_homepage]
      @title = "#{I18n.t('js.filters.categories.title')} - #{SiteSetting.title}"
    end

    respond_to do |format|
      format.html do
        store_preloaded(@category_list.preload_key, MultiJson.dump(CategoryListSerializer.new(@category_list, scope: guardian)))

        style = SiteSetting.desktop_category_page_style
        topic_options = {
          per_page: CategoriesController.topics_per_page,
          no_definitions: true
        }

        if style == "categories_and_latest_topics".freeze
          @topic_list = TopicQuery.new(current_user, topic_options).list_latest
          @topic_list.more_topics_url = url_for(public_send("latest_path"))
        elsif style == "categories_and_top_topics".freeze
          @topic_list = TopicQuery.new(nil, topic_options).list_top_for(SiteSetting.top_page_default_timeframe.to_sym)
          @topic_list.more_topics_url = url_for(public_send("top_path"))
        end

        if @topic_list.present? && @topic_list.topics.present?
          store_preloaded(
            @topic_list.preload_key,
            MultiJson.dump(TopicListSerializer.new(@topic_list, scope: guardian))
          )
        end

        render
      end

      format.json { render_serialized(@category_list, CategoryListSerializer) }
    end
  end

  def categories_and_latest
    categories_and_topics(:latest)
  end

  def categories_and_top
    categories_and_topics(:top)
  end

  def move
    guardian.ensure_can_create_category!

    params.require("category_id")
    params.require("position")

    if category = Category.find(params["category_id"])
      category.move_to(params["position"].to_i)
      render json: success_json
    else
      render status: 500, json: failed_json
    end
  end

  def reorder
    guardian.ensure_can_create_category!

    params.require(:mapping)
    change_requests = MultiJson.load(params[:mapping])
    by_category = Hash[change_requests.map { |cat, pos| [Category.find(cat.to_i), pos] }]

    unless guardian.is_admin?
      raise Discourse::InvalidAccess unless by_category.keys.all? { |c| guardian.can_see_category? c }
    end

    by_category.each do |cat, pos|
      cat.position = pos
      cat.save! if cat.will_save_change_to_position?
    end

    render json: success_json
  end

  def show
    guardian.ensure_can_see!(@category)

    if Category.topic_create_allowed(guardian).where(id: @category.id).exists?
      @category.permission = CategoryGroup.permission_types[:full]
    end
    render_serialized(@category, CategorySerializer)
  end

  def create
    guardian.ensure_can_create!(Category)
    position = category_params.delete(:position)

    @category =
      begin
        Category.new(category_params.merge(user: current_user))
      rescue ArgumentError => e
        return render json: { errors: [e.message] }, status: 422
      end

    if @category.save
      @category.move_to(position.to_i) if position

      Scheduler::Defer.later "Log staff action create category" do
        @staff_action_logger.log_category_creation(@category)
      end

      render_serialized(@category, CategorySerializer)
    else
      render_json_error(@category)
    end
  end

  def update
    guardian.ensure_can_edit!(@category)

    json_result(@category, serializer: CategorySerializer) do |cat|

      cat.move_to(category_params[:position].to_i) if category_params[:position]
      category_params.delete(:position)

      # properly null the value so the database constraint doesn't catch us
      category_params[:email_in] = nil if category_params[:email_in]&.blank?
      category_params[:minimum_required_tags] = 0 if category_params[:minimum_required_tags]&.blank?

      old_permissions = cat.permissions_params

      if result = cat.update(category_params)
        Scheduler::Defer.later "Log staff action change category settings" do
          @staff_action_logger.log_category_settings_change(@category, category_params, old_permissions)
        end
      end

      result
    end
  end

  def update_slug
    @category = Category.find(params[:category_id].to_i)
    guardian.ensure_can_edit!(@category)

    custom_slug = params[:slug].to_s

    if custom_slug.present? && @category.update(slug: custom_slug)
      render json: success_json
    else
      render_json_error(@category)
    end
  end

  def set_notifications
    category_id = params[:category_id].to_i
    notification_level = params[:notification_level].to_i

    CategoryUser.set_notification_level_for_category(current_user, notification_level, category_id)
    render json: success_json
  end

  def destroy
    guardian.ensure_can_delete!(@category)
    @category.destroy

    Scheduler::Defer.later "Log staff action delete category" do
      @staff_action_logger.log_category_deletion(@category)
    end

    render json: success_json
  end

  def find_by_slug
    params.require(:category_slug)
    @category = Category.find_by_slug(params[:category_slug], params[:parent_category_slug])

    raise Discourse::NotFound unless @category.present?

    if !guardian.can_see?(@category)
      if SiteSetting.detailed_404 && group = @category.access_category_via_group
        raise Discourse::InvalidAccess.new(
          'not in group',
          @category,
          custom_message: 'not_in_group.title_category',
          group: group
        )
      else
        raise Discourse::NotFound
      end
    end

    @category.permission = CategoryGroup.permission_types[:full] if Category.topic_create_allowed(guardian).where(id: @category.id).exists?
    render_serialized(@category, CategorySerializer)
  end

  private

  def self.topics_per_page
    return SiteSetting.categories_topics if SiteSetting.categories_topics > 0

    count = Category.where(parent_category: nil).count
    count = (SYMMETRICAL_CATEGORIES_TO_TOPICS_FACTOR * count).to_i
    count > MIN_CATEGORIES_TOPICS ? count : MIN_CATEGORIES_TOPICS
  end

  def categories_and_topics(topics_filter)
    discourse_expires_in 1.minute

    category_options = {
      is_homepage: current_homepage == "categories".freeze,
      parent_category_id: params[:parent_category_id],
      include_topics: false
    }

    topic_options = {
      per_page: CategoriesController.topics_per_page,
      no_definitions: true
    }

    result = CategoryAndTopicLists.new
    result.category_list = CategoryList.new(guardian, category_options)

    if topics_filter == :latest
      result.topic_list = TopicQuery.new(current_user, topic_options).list_latest
    elsif topics_filter == :top
      result.topic_list = TopicQuery.new(nil, topic_options).list_top_for(SiteSetting.top_page_default_timeframe.to_sym)
    end

    draft_key = Draft::NEW_TOPIC
    draft_sequence = DraftSequence.current(current_user, draft_key)
    draft = Draft.get(current_user, draft_key, draft_sequence) if current_user

    %w{category topic}.each do |type|
      result.public_send(:"#{type}_list").draft = draft
      result.public_send(:"#{type}_list").draft_key = draft_key
      result.public_send(:"#{type}_list").draft_sequence = draft_sequence
    end

    render_serialized(result, CategoryAndTopicListsSerializer, root: false)
  end

  def required_param_keys
    [:name, :color, :text_color]
  end

  def category_params
    @category_params ||= begin
      required_param_keys.each do |key|
        params.require(key)
      end

      if p = params[:permissions]
        p.each do |k, v|
          p[k] = v.to_i
        end
      end

      if SiteSetting.tagging_enabled
        params[:allowed_tags] ||= []
        params[:allowed_tag_groups] ||= []
        params[:required_tag_group_name] ||= ''
      end

      result = params.permit(
        *required_param_keys,
        :position,
        :email_in,
        :email_in_allow_strangers,
        :mailinglist_mirror,
        :all_topics_wiki,
        :parent_category_id,
        :auto_close_hours,
        :auto_close_based_on_last_post,
        :uploaded_logo_id,
        :uploaded_background_id,
        :slug,
        :allow_badges,
        :topic_template,
        :sort_order,
        :sort_ascending,
        :topic_featured_link_allowed,
        :show_subcategory_list,
        :num_featured_topics,
        :default_view,
        :subcategory_list_style,
        :default_top_period,
        :minimum_required_tags,
        :navigate_to_first_post_after_read,
        :search_priority,
        :allow_global_tags,
        :required_tag_group_name,
        :min_tags_from_required_group,
        custom_fields: [params[:custom_fields].try(:keys)],
        permissions: [*p.try(:keys)],
        allowed_tags: [],
        allowed_tag_groups: []
      )
      if SiteSetting.enable_category_group_review?
        result[:reviewable_by_group_id] = Group.find_by(name: params[:reviewable_by_group_name])&.id
      end

      result
    end
  end

  def fetch_category
    @category = Category.find_by_slug(params[:id]) || Category.find_by(id: params[:id].to_i)
  end

  def initialize_staff_action_logger
    @staff_action_logger = StaffActionLogger.new(current_user)
  end

  def include_topics(parent_category = nil)
    style = SiteSetting.desktop_category_page_style
    view_context.mobile_view? ||
      params[:include_topics] ||
      (parent_category && parent_category.subcategory_list_includes_topics?) ||
      style == "categories_with_featured_topics".freeze ||
      style == "categories_boxes_with_topics".freeze ||
      style == "categories_with_top_topics".freeze
  end
end
