# frozen_string_literal: true

class PostSerializer < BasicPostSerializer

  # To pass in additional information we might need
  INSTANCE_VARS ||= [
    :parent_post,
    :add_raw,
    :add_title,
    :single_post_link_counts,
    :draft_sequence,
    :post_actions,
    :all_post_actions,
    :add_excerpt
  ]

  INSTANCE_VARS.each do |v|
    self.public_send(:attr_accessor, v)
  end

  attributes :post_number,
             :post_type,
             :updated_at,
             :reply_count,
             :reply_to_post_number,
             :quote_count,
             :incoming_link_count,
             :reads,
             :readers_count,
             :score,
             :yours,
             :topic_id,
             :topic_slug,
             :topic_title,
             :topic_html_title,
             :category_id,
             :display_username,
             :primary_group_name,
             :primary_group_flair_url,
             :primary_group_flair_bg_color,
             :primary_group_flair_color,
             :version,
             :can_edit,
             :can_delete,
             :can_recover,
             :can_wiki,
             :link_counts,
             :read,
             :user_title,
             :reply_to_user,
             :bookmarked,
             :bookmarked_with_reminder,
             :bookmark_reminder_at,
             :bookmark_reminder_type,
             :raw,
             :actions_summary,
             :moderator?,
             :admin?,
             :staff?,
             :user_id,
             :draft_sequence,
             :hidden,
             :hidden_reason_id,
             :trust_level,
             :deleted_at,
             :deleted_by,
             :user_deleted,
             :edit_reason,
             :can_view_edit_history,
             :wiki,
             :user_custom_fields,
             :static_doc,
             :via_email,
             :is_auto_generated,
             :action_code,
             :action_code_who,
             :notice_type,
             :notice_args,
             :last_wiki_edit,
             :locked,
             :excerpt,
             :reviewable_id,
             :reviewable_score_count,
             :reviewable_score_pending_count

  def initialize(object, opts)
    super(object, opts)

    PostSerializer::INSTANCE_VARS.each do |name|
      if opts.include? name
        self.public_send("#{name}=", opts[name])
      end
    end
  end

  def topic_slug
    topic&.slug
  end

  def include_topic_title?
    @add_title
  end

  def include_topic_html_title?
    @add_title
  end

  def include_category_id?
    @add_title
  end

  def include_excerpt?
    @add_excerpt
  end

  def topic_title
    topic&.title
  end

  def topic_html_title
    topic&.fancy_title
  end

  def category_id
    topic&.category_id
  end

  def moderator?
    !!(object&.user&.moderator?)
  end

  def admin?
    !!(object&.user&.admin?)
  end

  def staff?
    !!(object&.user&.staff?)
  end

  def yours
    scope.user == object.user
  end

  def can_edit
    scope.can_edit?(object)
  end

  def can_delete
    scope.can_delete?(object)
  end

  def can_recover
    scope.can_recover_post?(object)
  end

  def can_wiki
    scope.can_wiki?(object)
  end

  def display_username
    object.user&.name
  end

  def primary_group_name
    return nil unless object.user && object.user.primary_group_id

    if @topic_view
      @topic_view.primary_group_names[object.user.primary_group_id]
    else
      object.user.primary_group.name if object.user.primary_group
    end
  end

  def primary_group_flair_url
    object.user&.primary_group&.flair_url
  end

  def primary_group_flair_bg_color
    object.user&.primary_group&.flair_bg_color
  end

  def primary_group_flair_color
    object.user&.primary_group&.flair_color
  end

  def link_counts
    return @single_post_link_counts if @single_post_link_counts.present?

    # TODO: This could be better, just porting the old one over
    @topic_view.link_counts[object.id].map do |link|
      result = {}
      result[:url] = link[:url]
      result[:internal] = link[:internal]
      result[:reflection] = link[:reflection]
      result[:title] = link[:title] if link[:title].present?
      result[:clicks] = link[:clicks] || 0
      result
    end
  end

  def read
    @topic_view.read?(object.post_number)
  end

  def score
    object.score || 0
  end

  def user_title
    object&.user&.title
  end

  def trust_level
    object&.user&.trust_level
  end

  def reply_to_user
    {
      username: object.reply_to_user.username,
      avatar_template: object.reply_to_user.avatar_template
    }
  end

  def deleted_by
    BasicUserSerializer.new(object.deleted_by, root: false).as_json
  end

  def include_deleted_by?
    scope.is_staff? && object.deleted_by.present?
  end

  # Helper function to decide between #post_actions and @all_post_actions
  def actions
    return post_actions if post_actions.present?
    return all_post_actions[object.id] if all_post_actions.present?
    nil
  end

  # Summary of the actions taken on this post
  def actions_summary
    result = []
    can_see_post = scope.can_see_post?(object)

    PostActionType.types.except(:bookmark).each do |sym, id|
      count_col = "#{sym}_count".to_sym

      count = object.public_send(count_col) if object.respond_to?(count_col)
      summary = { id: id, count: count }
      summary[:hidden] = true if sym == :vote

      if scope.post_can_act?(object, sym, opts: { taken_actions: actions }, can_see_post: can_see_post)
        summary[:can_act] = true
      end

      if sym == :notify_user &&
         (
           (scope.current_user.present? && scope.current_user == object.user) ||
           (object.user && object.user.bot?)
         )

        summary.delete(:can_act)
      end

      if actions.present? && actions.has_key?(id)
        summary[:acted] = true
        summary[:can_undo] = true if scope.can_delete?(actions[id])
      end

      # only show public data
      unless scope.is_staff? || PostActionType.public_types.values.include?(id)
        summary[:count] = summary[:acted] ? 1 : 0
      end

      summary.delete(:count) if summary[:count] == 0

      # Only include it if the user can do it or it has a count
      if summary[:can_act] || summary[:count]
        result << summary
      end
    end

    result
  end

  def include_draft_sequence?
    @draft_sequence.present?
  end

  def include_slug_title?
    @topic_slug.present?
  end

  def include_raw?
    @add_raw.present? && (!object.hidden || scope.user&.staff? || yours)
  end

  def include_link_counts?
    return true if @single_post_link_counts.present?

    @topic_view.present? && @topic_view.link_counts.present? && @topic_view.link_counts[object.id].present?
  end

  def include_read?
    @topic_view.present?
  end

  def include_reply_to_user?
    !(SiteSetting.suppress_reply_when_quoting && object.reply_quoted?) && object.reply_to_user
  end

  # this atrtribute is not even included unless include_bookmarked? is true,
  # which is why it is always true if included
  def bookmarked
    true
  end

  def bookmarked_with_reminder
    true
  end

  def include_bookmarked?
    (actions.present? && actions.keys.include?(PostActionType.types[:bookmark]))
  end

  def include_bookmarked_with_reminder?
    post_bookmark.present?
  end

  def include_bookmark_reminder_at?
    include_bookmarked_with_reminder?
  end

  def include_bookmark_reminder_type?
    include_bookmarked_with_reminder?
  end

  def post_bookmark
    return nil if !SiteSetting.enable_bookmarks_with_reminders? || @topic_view.blank?
    @post_bookmark ||= @topic_view.user_post_bookmarks.find { |bookmark| bookmark.post_id == object.id }
  end

  def bookmark_reminder_at
    post_bookmark&.reminder_at
  end

  def bookmark_reminder_type
    return if post_bookmark.blank?
    Bookmark.reminder_types[post_bookmark.reminder_type].to_s
  end

  def include_display_username?
    SiteSetting.enable_names?
  end

  def can_view_edit_history
    scope.can_view_edit_history?(object)
  end

  def user_custom_fields
    user_custom_fields_object[object.user_id]
  end

  def include_user_custom_fields?
    user_custom_fields_object[object.user_id]
  end

  def static_doc
    true
  end

  def include_static_doc?
    object.is_first_post? && Discourse.static_doc_topic_ids.include?(object.topic_id)
  end

  def include_via_email?
    object.via_email?
  end

  def is_auto_generated
    object.incoming_email&.is_auto_generated
  end

  def include_is_auto_generated?
    object.via_email? && is_auto_generated
  end

  def version
    return 1 if object.hidden && !scope.can_view_hidden_post_revisions?

    scope.is_staff? ? object.version : object.public_version
  end

  def include_action_code?
    object.action_code.present?
  end

  def action_code_who
    post_custom_fields["action_code_who"]
  end

  def include_action_code_who?
    include_action_code? && action_code_who.present?
  end

  def notice_type
    post_custom_fields[Post::NOTICE_TYPE]
  end

  def include_notice_type?
    case notice_type
    when Post.notices[:custom]
      return true
    when Post.notices[:new_user]
      min_trust_level = SiteSetting.new_user_notice_tl
    when Post.notices[:returning_user]
      min_trust_level = SiteSetting.returning_user_notice_tl
    else
      return false
    end

    scope.user && scope.user.id && object.user &&
    scope.user.id != object.user_id &&
    scope.user.has_trust_level?(min_trust_level)
  end

  def notice_args
    post_custom_fields[Post::NOTICE_ARGS]
  end

  def include_notice_args?
    notice_args.present? && include_notice_type?
  end

  def locked
    true
  end

  # Only show locked posts to the users who made the post and staff
  def include_locked?
    object.locked? && (yours || scope.is_staff?)
  end

  def last_wiki_edit
    object.revisions.last.updated_at
  end

  def include_last_wiki_edit?
    object.wiki &&
    object.post_number == 1 &&
    object.revisions.size > 0
  end

  def include_hidden_reason_id?
    object.hidden
  end

  # If we have a topic view, it has bulk values for the reviewable content we can use
  def reviewable_id
    if @topic_view.present?
      for_post = @topic_view.reviewable_counts[object.id]
      return for_post ? for_post[:reviewable_id] : 0
    end

    reviewable&.id
  end

  def include_reviewable_id?
    can_review_topic?
  end

  def reviewable_score_count
    if @topic_view.present?
      for_post = @topic_view.reviewable_counts[object.id]
      return for_post ? for_post[:total] : 0
    end

    reviewable_scores.size
  end

  def include_reviewable_score_count?
    can_review_topic?
  end

  def reviewable_score_pending_count
    if @topic_view.present?
      for_post = @topic_view.reviewable_counts[object.id]
      return for_post ? for_post[:pending] : 0
    end

    reviewable_scores.count { |rs| rs.pending? }
  end

  def include_reviewable_score_pending_count?
    can_review_topic?
  end

private

  def can_review_topic?
    return @can_review_topic unless @can_review_topic.nil?
    @can_review_topic = @topic_view&.can_review_topic
    @can_review_topic ||= scope.can_review_topic?(object.topic)
    @can_review_topic
  end

  def reviewable
    @reviewable ||= Reviewable.where(target: object).includes(:reviewable_scores).first
  end

  def reviewable_scores
    reviewable&.reviewable_scores&.to_a || []
  end

  def user_custom_fields_object
    (@topic_view&.user_custom_fields || @options[:user_custom_fields] || {})
  end

  def topic
    @topic = object.topic
    @topic ||= Topic.with_deleted.find_by(id: object.topic_id) if scope.is_staff?
    @topic
  end

  def post_actions
    @post_actions ||= (@topic_view&.all_post_actions || {})[object.id]
  end

end
