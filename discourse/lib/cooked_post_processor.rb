# frozen_string_literal: true

# Post processing that we can do after a post has already been cooked.
# For example, inserting the onebox content, or image sizes/thumbnails.

class CookedPostProcessor
  INLINE_ONEBOX_LOADING_CSS_CLASS = "inline-onebox-loading"
  INLINE_ONEBOX_CSS_CLASS = "inline-onebox"
  LIGHTBOX_WRAPPER_CSS_CLASS = "lightbox-wrapper"
  LOADING_SIZE = 10
  LOADING_COLORS = 32

  attr_reader :cooking_options, :doc

  def initialize(post, opts = {})
    @dirty = false
    @opts = opts
    @post = post
    @previous_cooked = (@post.cooked || "").dup
    # NOTE: we re-cook the post here in order to prevent timing issues with edits
    # cf. https://meta.discourse.org/t/edit-of-rebaked-post-doesnt-show-in-html-only-in-raw/33815/6
    @cooking_options = post.cooking_options || opts[:cooking_options] || {}
    @cooking_options[:topic_id] = post.topic_id
    @cooking_options = @cooking_options.symbolize_keys

    cooked = post.cook(post.raw, @cooking_options)
    @doc = Nokogiri::HTML::fragment(cooked)
    @has_oneboxes = post.post_analyzer.found_oneboxes?
    @size_cache = {}

    @disable_loading_image = !!opts[:disable_loading_image]
    @omit_nofollow = post.omit_nofollow?
  end

  def post_process(bypass_bump: false, new_post: false)
    DistributedMutex.synchronize("post_process_#{@post.id}", validity: 10.minutes) do
      DiscourseEvent.trigger(:before_post_process_cooked, @doc, @post)
      remove_full_quote_on_direct_reply if new_post
      post_process_oneboxes
      post_process_images
      post_process_quotes
      optimize_urls
      remove_user_ids
      update_post_image
      enforce_nofollow
      pull_hotlinked_images(bypass_bump)
      grant_badges
      @post.link_post_uploads(fragments: @doc)
      DiscourseEvent.trigger(:post_process_cooked, @doc, @post)
      nil
    end
  end

  def has_emoji?
    (@doc.css("img.emoji") - @doc.css(".quote img")).size > 0
  end

  def grant_badges
    return if @post.user.blank? || !Guardian.new.can_see?(@post)

    BadgeGranter.grant(Badge.find(Badge::FirstEmoji), @post.user, post_id: @post.id) if has_emoji?
    BadgeGranter.grant(Badge.find(Badge::FirstOnebox), @post.user, post_id: @post.id) if @has_oneboxes
    BadgeGranter.grant(Badge.find(Badge::FirstReplyByEmail), @post.user, post_id: @post.id) if @post.is_reply_by_email?
  end

  def post_process_quotes
    @doc.css("aside.quote").each do |q|
      post_number = q['data-post']
      topic_id = q['data-topic']
      if topic_id && post_number
        comparer = QuoteComparer.new(
          topic_id.to_i,
          post_number.to_i,
          q.css('blockquote').text
        )

        if comparer.modified?
          q['class'] = ((q['class'] || '') + " quote-modified").strip
        end
      end
    end
  end

  def remove_full_quote_on_direct_reply
    return if !SiteSetting.remove_full_quote
    return if @post.post_number == 1
    return if @doc.xpath("aside[contains(@class, 'quote')]").size != 1

    previous = Post
      .where("post_number < ? AND topic_id = ? AND post_type = ? AND NOT hidden", @post.post_number, @post.topic_id, Post.types[:regular])
      .order("post_number DESC")
      .limit(1)
      .pluck(:cooked)
      .first

    return if previous.blank?

    previous_text = Nokogiri::HTML::fragment(previous).text.strip
    quoted_text = @doc.css("aside.quote:first-child blockquote").first&.text&.strip || ""

    return if previous_text.gsub(/(\s){2,}/, '\1') != quoted_text.gsub(/(\s){2,}/, '\1')

    quote_regexp = /\A\s*\[quote.+\[\/quote\]/im
    quoteless_raw = @post.raw.sub(quote_regexp, "").strip

    return if @post.raw.strip == quoteless_raw

    PostRevisor.new(@post).revise!(
      Discourse.system_user,
      {
        raw: quoteless_raw,
        edit_reason: I18n.t(:removed_direct_reply_full_quotes)
      },
      skip_validations: true,
      bypass_bump: true
    )
  end

  def add_image_placeholder!(img)
    src = img["src"].sub(/^https?:/i, "")

    if large_images.include?(src)
      return add_large_image_placeholder!(img)
    elsif broken_images.include?(src)
      return add_broken_image_placeholder!(img)
    end

    false
  end

  def add_large_image_placeholder!(img)
    url = img["src"]

    is_hyperlinked = is_a_hyperlink?(img)

    placeholder = create_node("div", "large-image-placeholder")
    img.add_next_sibling(placeholder)
    placeholder.add_child(img)

    a = create_link_node(nil, url, true)
    img.add_next_sibling(a)

    span = create_span_node("url", url)
    a.add_child(span)
    span.add_previous_sibling(create_icon_node("far-image"))
    span.add_next_sibling(create_span_node("help", I18n.t("upload.placeholders.too_large", max_size_kb: SiteSetting.max_image_size_kb)))

    # Only if the image is already linked
    if is_hyperlinked
      parent = placeholder.parent
      parent.add_next_sibling(placeholder)

      if parent.name == 'a' && parent["href"].present?
        if url == parent["href"]
          parent.remove
        else
          parent["class"] = "link"
          a.add_previous_sibling(parent)

          lspan = create_span_node("url", parent["href"])
          parent.add_child(lspan)
          lspan.add_previous_sibling(create_icon_node("link"))
        end
      end
    end

    img.remove
    true
  end

  def add_broken_image_placeholder!(img)
    img.name = "span"
    img.set_attribute("class", "broken-image")
    img.set_attribute("title", I18n.t("post.image_placeholder.broken"))
    img << "<svg class=\"fa d-icon d-icon-unlink svg-icon\" aria-hidden=\"true\"><use xlink:href=\"#unlink\"></use></svg>"
    img.remove_attribute("src")
    img.remove_attribute("width")
    img.remove_attribute("height")
    true
  end

  def large_images
    @large_images ||=
      begin
        JSON.parse(@post.custom_fields[Post::LARGE_IMAGES].presence || "[]")
      rescue JSON::ParserError
        []
      end
  end

  def broken_images
    @broken_images ||=
      begin
        JSON.parse(@post.custom_fields[Post::BROKEN_IMAGES].presence || "[]")
      rescue JSON::ParserError
        []
      end
  end

  def downloaded_images
    @downloaded_images ||= @post.downloaded_images
  end

  def extract_images
    # all images with a src attribute
    @doc.css("img[src]") -
    # minus data images
    @doc.css("img[src^='data']") -
    # minus emojis
    @doc.css("img.emoji")
  end

  def extract_images_for_post
    # all images with a src attribute
    @doc.css("img[src]") -
    # minus emojis
    @doc.css("img.emoji") -
    # minus images inside quotes
    @doc.css(".quote img") -
    # minus onebox site icons
    @doc.css("img.site-icon")
  end

  def oneboxed_images
    @doc.css(".onebox-body img, .onebox img, img.onebox")
  end

  def limit_size!(img)
    # retrieve the size from
    #  1) the width/height attributes
    #  2) the dimension from the preview (image_sizes)
    #  3) the dimension of the original image (HTTP request)
    w, h = get_size_from_attributes(img) ||
           get_size_from_image_sizes(img["src"], @opts[:image_sizes]) ||
           get_size(img["src"])

    # limit the size of the thumbnail
    img["width"], img["height"] = ImageSizer.resize(w, h)
  end

  def get_size_from_attributes(img)
    w, h = img["width"].to_i, img["height"].to_i
    return [w, h] unless w <= 0 || h <= 0
    # if only width or height are specified attempt to scale image
    if w > 0 || h > 0
      w = w.to_f
      h = h.to_f

      return unless original_image_size = get_size(img["src"])
      original_width, original_height = original_image_size.map(&:to_f)

      if w > 0
        ratio = w / original_width
        [w.floor, (original_height * ratio).floor]
      else
        ratio = h / original_height
        [(original_width * ratio).floor, h.floor]
      end
    end
  end

  def get_size_from_image_sizes(src, image_sizes)
    return unless image_sizes.present?
    image_sizes.each do |image_size|
      url, size = image_size[0], image_size[1]
      if url && url.include?(src) &&
         size && size["width"].to_i > 0 && size["height"].to_i > 0
        return [size["width"], size["height"]]
      end
    end
    nil
  end

  def add_to_size_cache(url, w, h)
    @size_cache[url] = [w, h]
  end

  def get_size(url)
    return @size_cache[url] if @size_cache.has_key?(url)

    absolute_url = url
    absolute_url = Discourse.base_url_no_prefix + absolute_url if absolute_url =~ /^\/[^\/]/

    return unless absolute_url

    # FastImage fails when there's no scheme
    absolute_url = SiteSetting.scheme + ":" + absolute_url if absolute_url.start_with?("//")

    # we can't direct FastImage to our secure-media-uploads url because it bounces
    # anonymous requests with a 404 error
    if url && Upload.secure_media_url?(url)
      absolute_url = Upload.signed_url_from_secure_media_url(absolute_url)
    end

    return unless is_valid_image_url?(absolute_url)

    # we can *always* crawl our own images
    return unless SiteSetting.crawl_images? || Discourse.store.has_been_uploaded?(url)

    @size_cache[url] = FastImage.size(absolute_url)
  rescue Zlib::BufError, URI::Error, OpenSSL::SSL::SSLError
    # FastImage.size raises BufError for some gifs, leave it.
  end

  def is_valid_image_url?(url)
    uri = URI.parse(url)
    %w(http https).include? uri.scheme
  rescue URI::Error
  end

  def convert_to_link!(img)
    w, h = img["width"].to_i, img["height"].to_i
    user_width, user_height = (w > 0 && h > 0 && [w, h]) ||
                              get_size_from_attributes(img) ||
                              get_size_from_image_sizes(img["src"], @opts[:image_sizes])

    limit_size!(img)

    src = img["src"]
    return if src.blank? || is_a_hyperlink?(img) || is_svg?(img)

    original_width, original_height = (get_size(src) || [0, 0]).map(&:to_i)
    if original_width == 0 || original_height == 0
      Rails.logger.info "Can't reach '#{src}' to get its dimension."
      return
    end

    return if original_width <= SiteSetting.max_image_width && original_height <= SiteSetting.max_image_height

    user_width, user_height = [original_width, original_height] if user_width.to_i <= 0 && user_height.to_i <= 0
    width, height = user_width, user_height

    crop = SiteSetting.min_ratio_to_crop > 0 && width.to_f / height.to_f < SiteSetting.min_ratio_to_crop

    if crop
      width, height = ImageSizer.crop(width, height)
      img["width"], img["height"] = width, height
    else
      width, height = ImageSizer.resize(width, height)
    end

    # if the upload already exists and is attached to a different post,
    # or the original_sha1 is missing meaning it was created before secure
    # media was enabled. we want to re-thumbnail and re-optimize in this case
    # to avoid using uploads linked to many other posts
    upload = Upload.consider_for_reuse(Upload.get_from_url(src), @post)

    if upload.present?
      upload.create_thumbnail!(width, height, crop: crop)

      each_responsive_ratio do |ratio|
        resized_w = (width * ratio).to_i
        resized_h = (height * ratio).to_i

        if upload.width && resized_w <= upload.width
          upload.create_thumbnail!(resized_w, resized_h, crop: crop)
        end
      end

      unless @disable_loading_image
        upload.create_thumbnail!(LOADING_SIZE, LOADING_SIZE, format: 'png', colors: LOADING_COLORS)
      end
    end

    if img.ancestors('.onebox, .onebox-body, .quote').blank? && !img.classes.include?("onebox")
      add_lightbox!(img, original_width, original_height, upload, cropped: crop)
    end

    if upload.present?
      optimize_image!(img, upload, cropped: crop)
    end
  end

  def loading_image(upload)
    upload.thumbnail(LOADING_SIZE, LOADING_SIZE)
  end

  def is_a_hyperlink?(img)
    parent = img.parent
    while parent
      return true if parent.name == "a"
      parent = parent.parent if parent.respond_to?(:parent)
    end
    false
  end

  def each_responsive_ratio
    SiteSetting
      .responsive_post_image_sizes
      .split('|')
      .map(&:to_f)
      .sort
      .each { |r| yield r if r > 1 }
  end

  def optimize_image!(img, upload, cropped: false)
    w, h = img["width"].to_i, img["height"].to_i

    # note: optimize_urls cooks the src and data-small-upload further after this
    thumbnail = upload.thumbnail(w, h)
    if thumbnail && thumbnail.filesize.to_i < upload.filesize
      img["src"] = thumbnail.url

      srcset = +""

      each_responsive_ratio do |ratio|
        resized_w = (w * ratio).to_i
        resized_h = (h * ratio).to_i

        if !cropped && upload.width && resized_w > upload.width
          cooked_url = UrlHelper.cook_url(upload.url, secure: @post.with_secure_media?)
          srcset << ", #{cooked_url} #{ratio.to_s.sub(/\.0$/, "")}x"
        elsif t = upload.thumbnail(resized_w, resized_h)
          cooked_url = UrlHelper.cook_url(t.url, secure: @post.with_secure_media?)
          srcset << ", #{cooked_url} #{ratio.to_s.sub(/\.0$/, "")}x"
        end

        img["srcset"] = "#{UrlHelper.cook_url(img["src"], secure: @post.with_secure_media?)}#{srcset}" if srcset.present?
      end
    else
      img["src"] = upload.url
    end

    if small_upload = loading_image(upload)
      img["data-small-upload"] = small_upload.url
    end
  end

  def add_lightbox!(img, original_width, original_height, upload, cropped: false)
    # first, create a div to hold our lightbox
    lightbox = create_node("div", LIGHTBOX_WRAPPER_CSS_CLASS)
    img.add_next_sibling(lightbox)
    lightbox.add_child(img)

    # then, the link to our larger image
    src = UrlHelper.cook_url(img["src"], secure: @post.with_secure_media?)
    a = create_link_node("lightbox", src)
    img.add_next_sibling(a)

    if upload
      a["data-download-href"] = Discourse.store.download_url(upload)
    end

    a.add_child(img)

    # then, some overlay informations
    meta = create_node("div", "meta")
    img.add_next_sibling(meta)

    filename = get_filename(upload, img["src"])
    informations = +"#{original_width}×#{original_height}"
    informations << " #{upload.human_filesize}" if upload

    a["title"] = CGI.escapeHTML(img["title"] || img["alt"] || filename)

    meta.add_child create_icon_node("far-image")
    meta.add_child create_span_node("filename", a["title"])
    meta.add_child create_span_node("informations", informations)
    meta.add_child create_icon_node("discourse-expand")
  end

  def get_filename(upload, src)
    return File.basename(src) unless upload
    return upload.original_filename unless upload.original_filename =~ /^blob(\.png)?$/i
    I18n.t("upload.pasted_image_filename")
  end

  def create_node(tag_name, klass)
    node = Nokogiri::XML::Node.new(tag_name, @doc)
    node["class"] = klass if klass.present?
    node
  end

  def create_span_node(klass, content = nil)
    span = create_node("span", klass)
    span.content = content if content
    span
  end

  def create_icon_node(klass)
    icon = create_node("svg", "fa d-icon d-icon-#{klass} svg-icon")
    icon.set_attribute("aria-hidden", "true")
    icon << "<use xlink:href=\"##{klass}\"></use>"

  end

  def create_link_node(klass, url, external = false)
    a = create_node("a", klass)
    a["href"] = url
    if external
      a["target"] = "_blank"
      a["rel"] = "nofollow noopener"
    end
    a
  end

  def update_post_image
    img = extract_images_for_post.first
    if img.blank?
      @post.update_column(:image_url, nil) if @post.image_url
      @post.topic.update_column(:image_url, nil) if @post.topic.image_url && @post.is_first_post?
      return
    end

    if img["src"].present?
      @post.update_column(:image_url, img["src"][0...255]) # post
      @post.topic.update_column(:image_url, img["src"][0...255]) if @post.is_first_post? # topic
    end
  end

  def post_process_oneboxes
    limit = SiteSetting.max_oneboxes_per_post
    oneboxes = {}
    inlineOneboxes = {}

    Oneboxer.apply(@doc, extra_paths: [".#{INLINE_ONEBOX_LOADING_CSS_CLASS}"]) do |url, element|
      is_onebox = element["class"] == Oneboxer::ONEBOX_CSS_CLASS
      map = is_onebox ? oneboxes : inlineOneboxes
      skip_onebox = limit <= 0 && !map[url]

      if skip_onebox
        if is_onebox
          element.remove_class('onebox')
        else
          remove_inline_onebox_loading_class(element)
        end

        next
      end

      limit -= 1
      map[url] = true

      if is_onebox
        onebox = Oneboxer.onebox(url,
          invalidate_oneboxes: !!@opts[:invalidate_oneboxes],
          user_id: @post&.user_id,
          category_id: @post&.topic&.category_id
        )

        @has_oneboxes = true if onebox.present?
        onebox
      else
        process_inline_onebox(element)
        false
      end
    end

    oneboxed_images.each do |img|
      next if img["src"].blank?

      src = img["src"].sub(/^https?:/i, "")
      parent = img.parent
      img_classes = (img["class"] || "").split(" ")
      link_classes = ((parent&.name == "a" && parent["class"]) || "").split(" ")

      if img_classes.include?("onebox") || link_classes.include?("onebox")
        next if add_image_placeholder!(img)
      elsif large_images.include?(src) || broken_images.include?(src)
        img.remove
        next
      end

      upload_id = downloaded_images[src]
      upload = Upload.find_by_id(upload_id) if upload_id

      if upload.present?
        img["src"] = UrlHelper.cook_url(upload.url, secure: @post.with_secure_media?)
      end

      # make sure we grab dimensions for oneboxed images
      # and wrap in a div
      limit_size!(img)

      next if img["class"]&.include?('onebox-avatar')

      parent = parent&.parent if parent&.name == "a"
      parent_class = parent && parent["class"]
      width = img["width"].to_i
      height = img["height"].to_i

      if parent_class&.include?("onebox-body") && width > 0 && height > 0
        # special instruction for width == height, assume we are dealing with an avatar
        if (img["width"].to_i == img["height"].to_i)
          found = false
          parent = img
          while parent = parent.parent
            if parent["class"] && parent["class"].include?("whitelistedgeneric")
              found = true
              break
            end
          end

          if found
            img["class"] = img["class"].to_s + " onebox-avatar"
            next
          end
        end

        if width < 64 && height < 64
          img["class"] = img["class"].to_s + " onebox-full-image"
        else
          img.delete('width')
          img.delete('height')
          new_parent = img.add_next_sibling("<div class='aspect-image' style='--aspect-ratio:#{width}/#{height};'/>")
          new_parent.first.add_child(img)
        end
      elsif (parent_class&.include?("instagram-images") || parent_class&.include?("tweet-images") || parent_class&.include?("scale-images")) && width > 0 && height > 0
        img.remove_attribute("width")
        img.remove_attribute("height")
        parent["class"] = "aspect-image-full-size"
        parent["style"] = "--aspect-ratio:#{width}/#{height};"
      end
    end

    if @omit_nofollow || !SiteSetting.add_rel_nofollow_to_user_content
      @doc.css(".onebox-body a, .onebox a").each { |a| a.remove_attribute("rel") }
    end
  end

  def optimize_urls
    %w{href data-download-href}.each do |selector|
      @doc.css("a[#{selector}]").each do |a|
        a[selector] = UrlHelper.cook_url(a[selector].to_s)
      end
    end

    %w{src data-small-upload}.each do |selector|
      @doc.css("img[#{selector}]").each do |img|
        img[selector] = UrlHelper.cook_url(img[selector].to_s, secure: @post.with_secure_media?)
      end
    end
  end

  def remove_user_ids
    @doc.css("a[href]").each do |a|
      uri = begin
        URI(a["href"])
      rescue URI::Error
        next
      end
      next if uri.hostname != Discourse.current_hostname

      query = Rack::Utils.parse_nested_query(uri.query)
      next if !query.delete("u")

      uri.query = query.map { |k, v| "#{k}=#{v}" }.join("&").presence
      a["href"] = uri.to_s
    end
  end

  def enforce_nofollow
    if !@omit_nofollow && SiteSetting.add_rel_nofollow_to_user_content
      PrettyText.add_rel_nofollow_to_user_content(@doc)
    end
  end

  def pull_hotlinked_images(bypass_bump = false)
    # have we enough disk space?
    disable_if_low_on_disk_space # But still enqueue the job
    # don't download remote images for posts that are more than n days old
    return unless @post.created_at > (Date.today - SiteSetting.download_remote_images_max_days_old)
    # we only want to run the job whenever it's changed by a user
    return if @post.last_editor_id && @post.last_editor_id <= 0
    # make sure no other job is scheduled
    Jobs.cancel_scheduled_job(:pull_hotlinked_images, post_id: @post.id)
    # schedule the job
    delay = SiteSetting.editing_grace_period + 1
    Jobs.enqueue_in(delay.seconds.to_i, :pull_hotlinked_images, post_id: @post.id, bypass_bump: bypass_bump)
  end

  def disable_if_low_on_disk_space
    return false if Discourse.store.external?
    return false if !SiteSetting.download_remote_images_to_local
    return false if available_disk_space >= SiteSetting.download_remote_images_threshold

    SiteSetting.download_remote_images_to_local = false
    # log the site setting change
    reason = I18n.t("disable_remote_images_download_reason")
    staff_action_logger = StaffActionLogger.new(Discourse.system_user)
    staff_action_logger.log_site_setting_change("download_remote_images_to_local", true, false, details: reason)

    # also send a private message to the site contact user
    notify_about_low_disk_space

    true
  end

  def notify_about_low_disk_space
    SystemMessage.create_from_system_user(Discourse.site_contact_user, :download_remote_images_disabled)
  end

  def available_disk_space
    100 - DiskSpace.percent_free("#{Rails.root}/public/uploads")
  end

  def dirty?
    @previous_cooked != html
  end

  def html
    @doc.try(:to_html)
  end

  private

  def post_process_images
    extract_images.each do |img|
      convert_to_link!(img) unless add_image_placeholder!(img)
    end
  end

  def process_inline_onebox(element)
    inline_onebox = InlineOneboxer.lookup(
      element.attributes["href"].value,
      invalidate: !!@opts[:invalidate_oneboxes],
      user_id: @post&.user_id,
      category_id: @post&.topic&.category_id
    )

    if title = inline_onebox&.dig(:title)
      element.children = CGI.escapeHTML(title)
      element.add_class(INLINE_ONEBOX_CSS_CLASS)
    end

    remove_inline_onebox_loading_class(element)
  end

  def remove_inline_onebox_loading_class(element)
    element.remove_class(INLINE_ONEBOX_LOADING_CSS_CLASS)
  end

  def is_svg?(img)
    path =
      begin
        URI(img["src"]).path
      rescue URI::Error
        nil
      end

    File.extname(path) == '.svg' if path
  end

end
