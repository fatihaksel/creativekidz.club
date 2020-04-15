import { isEmpty } from "@ember/utils";
import { and, or, alias, reads } from "@ember/object/computed";
import { debounce } from "@ember/runloop";
import { inject as service } from "@ember/service";
import { inject } from "@ember/controller";
import Controller from "@ember/controller";
import DiscourseURL from "discourse/lib/url";
import { buildQuote } from "discourse/lib/quote";
import Draft from "discourse/models/draft";
import Composer from "discourse/models/composer";
import discourseComputed, {
  observes,
  on
} from "discourse-common/utils/decorators";
import { getOwner } from "discourse-common/lib/get-owner";
import { escapeExpression, safariHacksDisabled } from "discourse/lib/utilities";
import {
  authorizesOneOrMoreExtensions,
  uploadIcon
} from "discourse/lib/uploads";
import { emojiUnescape } from "discourse/lib/text";
import { shortDate } from "discourse/lib/formatter";
import { SAVE_LABELS, SAVE_ICONS } from "discourse/models/composer";
import { Promise } from "rsvp";
import ENV from "discourse-common/config/environment";
import EmberObject, { computed } from "@ember/object";
import deprecated from "discourse-common/lib/deprecated";

function loadDraft(store, opts) {
  let promise = Promise.resolve();

  opts = opts || {};

  let draft = opts.draft;
  const draftKey = opts.draftKey;
  const draftSequence = opts.draftSequence;

  try {
    if (draft && typeof draft === "string") {
      draft = JSON.parse(draft);
    }
  } catch (error) {
    draft = null;
    Draft.clear(draftKey, draftSequence);
  }
  if (
    draft &&
    ((draft.title && draft.title !== "") || (draft.reply && draft.reply !== ""))
  ) {
    const composer = store.createRecord("composer");
    const serializedFields = Composer.serializedFieldsForDraft();

    let attrs = {
      draftKey,
      draftSequence,
      draft: true,
      composerState: Composer.DRAFT,
      topic: opts.topic
    };

    serializedFields.forEach(f => {
      attrs[f] = draft[f] || opts[f];
    });

    promise = promise.then(() => composer.open(attrs)).then(() => composer);
  }

  return promise;
}

const _popupMenuOptionsCallbacks = [];

let _checkDraftPopup = !ENV.environment === "test";

export function toggleCheckDraftPopup(enabled) {
  _checkDraftPopup = enabled;
}

export function clearPopupMenuOptionsCallback() {
  _popupMenuOptionsCallbacks.length = 0;
}

export function addPopupMenuOptionsCallback(callback) {
  _popupMenuOptionsCallbacks.push(callback);
}

export default Controller.extend({
  topicController: inject("topic"),
  router: service(),

  checkedMessages: false,
  messageCount: null,
  showEditReason: false,
  editReason: null,
  scopedCategoryId: null,
  lastValidatedAt: null,
  isUploading: false,
  allowUpload: false,
  uploadIcon: "upload",
  topic: null,
  linkLookup: null,
  showPreview: true,
  forcePreview: and("site.mobileView", "showPreview"),
  whisperOrUnlistTopic: or("isWhispering", "model.unlistTopic"),
  categories: alias("site.categoriesList"),

  @on("init")
  _setupPreview() {
    const val = this.site.mobileView
      ? false
      : this.keyValueStore.get("composer.showPreview") || "true";
    this.set("showPreview", val === "true");
  },

  @discourseComputed("showPreview")
  toggleText(showPreview) {
    return showPreview
      ? I18n.t("composer.hide_preview")
      : I18n.t("composer.show_preview");
  },

  @observes("showPreview")
  showPreviewChanged() {
    if (!this.site.mobileView) {
      this.keyValueStore.set({
        key: "composer.showPreview",
        value: this.showPreview
      });
    }
  },

  @discourseComputed(
    "model.replyingToTopic",
    "model.creatingPrivateMessage",
    "model.targetRecipients",
    "model.composeState"
  )
  focusTarget(replyingToTopic, creatingPM, usernames, composeState) {
    if (this.capabilities.isIOS && !safariHacksDisabled()) {
      return "none";
    }

    // Focus on usernames if it's blank or if it's just you
    usernames = usernames || "";
    if (
      (creatingPM && usernames.length === 0) ||
      usernames === this.currentUser.username
    ) {
      return "usernames";
    }

    if (replyingToTopic) {
      return "reply";
    }

    if (composeState === Composer.FULLSCREEN) {
      return "editor";
    }

    return "title";
  },

  showToolbar: computed({
    get() {
      const keyValueStore = getOwner(this).lookup("key-value-store:main");
      const storedVal = keyValueStore.get("toolbar-enabled");
      if (this._toolbarEnabled === undefined && storedVal === undefined) {
        // iPhone 6 is 375, anything narrower and toolbar should
        // be default disabled.
        // That said we should remember the state
        this._toolbarEnabled =
          window.innerWidth > 370 && !this.capabilities.isAndroid;
      }
      return this._toolbarEnabled || storedVal === "true";
    },
    set(key, val) {
      const keyValueStore = getOwner(this).lookup("key-value-store:main");
      this._toolbarEnabled = val;
      keyValueStore.set({
        key: "toolbar-enabled",
        value: val ? "true" : "false"
      });
      return val;
    }
  }),

  topicModel: alias("topicController.model"),

  @discourseComputed("model.canEditTitle", "model.creatingPrivateMessage")
  canEditTags(canEditTitle, creatingPrivateMessage) {
    return (
      this.site.can_tag_topics &&
      canEditTitle &&
      !creatingPrivateMessage &&
      (!this.get("model.topic.isPrivateMessage") || this.site.can_tag_pms)
    );
  },

  @discourseComputed("model.editingPost", "model.topic.details.can_edit")
  disableCategoryChooser(editingPost, canEditTopic) {
    return editingPost && !canEditTopic;
  },

  @discourseComputed("model.editingPost", "model.topic.canEditTags")
  disableTagsChooser(editingPost, canEditTags) {
    return editingPost && !canEditTags;
  },

  isStaffUser: reads("currentUser.staff"),

  canUnlistTopic: and("model.creatingTopic", "isStaffUser"),

  @discourseComputed("canWhisper", "replyingToWhisper")
  showWhisperToggle(canWhisper, replyingToWhisper) {
    return canWhisper && !replyingToWhisper;
  },

  @discourseComputed("model.post")
  replyingToWhisper(repliedToPost) {
    return (
      repliedToPost && repliedToPost.post_type === this.site.post_types.whisper
    );
  },

  isWhispering: or("replyingToWhisper", "model.whisper"),

  @discourseComputed("model.action", "isWhispering")
  saveIcon(action, isWhispering) {
    if (isWhispering) return "far-eye-slash";

    return SAVE_ICONS[action];
  },

  @discourseComputed("model.action", "isWhispering", "model.editConflict")
  saveLabel(action, isWhispering, editConflict) {
    if (editConflict) return "composer.overwrite_edit";
    else if (isWhispering) return "composer.create_whisper";

    return SAVE_LABELS[action];
  },

  @discourseComputed("isStaffUser", "model.action")
  canWhisper(isStaffUser, action) {
    return (
      this.siteSettings.enable_whispers &&
      isStaffUser &&
      Composer.REPLY === action
    );
  },

  _setupPopupMenuOption(callback) {
    let option = callback(this);
    if (typeof option === "undefined") {
      return null;
    }

    if (typeof option.condition === "undefined") {
      option.condition = true;
    } else if (typeof option.condition === "boolean") {
      // uses existing value
    } else {
      option.condition = this.get(option.condition);
    }

    return option;
  },

  @discourseComputed("model.composeState", "model.creatingTopic", "model.post")
  popupMenuOptions(composeState) {
    if (composeState === "open" || composeState === "fullscreen") {
      const options = [];

      options.push(
        this._setupPopupMenuOption(() => {
          return {
            action: "toggleInvisible",
            icon: "far-eye-slash",
            label: "composer.toggle_unlisted",
            condition: "canUnlistTopic"
          };
        })
      );

      options.push(
        this._setupPopupMenuOption(() => {
          return {
            action: "toggleWhisper",
            icon: "far-eye-slash",
            label: "composer.toggle_whisper",
            condition: "showWhisperToggle"
          };
        })
      );

      return options.concat(
        _popupMenuOptionsCallbacks
          .map(callback => this._setupPopupMenuOption(callback))
          .filter(o => o)
      );
    }
  },

  @discourseComputed("model.creatingPrivateMessage", "model.targetRecipients")
  showWarning(creatingPrivateMessage, usernames) {
    if (!this.get("currentUser.staff")) {
      return false;
    }

    const hasTargetGroups = this.get("model.hasTargetGroups");

    // We need exactly one user to issue a warning
    if (
      isEmpty(usernames) ||
      usernames.split(",").length !== 1 ||
      hasTargetGroups
    ) {
      return false;
    }

    return creatingPrivateMessage;
  },

  @discourseComputed("model.topic.title")
  draftTitle(topicTitle) {
    return emojiUnescape(escapeExpression(topicTitle));
  },

  @discourseComputed
  allowUpload() {
    return authorizesOneOrMoreExtensions(this.currentUser.staff);
  },

  @discourseComputed()
  uploadIcon() {
    return uploadIcon(this.currentUser.staff);
  },

  actions: {
    togglePreview() {
      this.toggleProperty("showPreview");
    },

    closeComposer() {
      this.close();
    },

    openComposer(options, post, topic) {
      this.open(options).then(() => {
        let url;
        if (post) url = post.url;
        if (!post && topic) url = topic.url;

        let topicTitle;
        if (topic) topicTitle = topic.title;

        if (!url || !topicTitle) return;

        url = `${location.protocol}//${location.host}${url}`;
        const link = `[${Handlebars.escapeExpression(topicTitle)}](${url})`;
        const continueDiscussion = I18n.t("post.continue_discussion", {
          postLink: link
        });

        const reply = this.get("model.reply");
        if (!reply || !reply.includes(continueDiscussion)) {
          this.model.prependText(continueDiscussion, {
            new_line: true
          });
        }
      });
    },

    cancelUpload() {
      this.set("model.uploadCancelled", true);
    },

    onPopupMenuAction(action) {
      this.send(action);
    },

    storeToolbarState(toolbarEvent) {
      this.set("toolbarEvent", toolbarEvent);
    },

    typed() {
      this.checkReplyLength();
      this.model.typing();
    },

    cancelled() {
      this.send("hitEsc");
    },

    addLinkLookup(linkLookup) {
      this.set("linkLookup", linkLookup);
    },

    afterRefresh($preview) {
      const topic = this.get("model.topic");
      const linkLookup = this.linkLookup;

      if (!topic || !linkLookup) {
        return;
      }

      // Don't check if there's only one post
      if (topic.posts_count === 1) {
        return;
      }

      const post = this.get("model.post");
      const $links = $("a[href]", $preview);
      $links.each((idx, l) => {
        const href = $(l).prop("href");
        if (href && href.length) {
          const [warn, info] = linkLookup.check(post, href);

          if (warn) {
            const body = I18n.t("composer.duplicate_link", {
              domain: info.domain,
              username: info.username,
              post_url: topic.urlForPostNumber(info.post_number),
              ago: shortDate(info.posted_at)
            });
            this.appEvents.trigger("composer-messages:create", {
              extraClass: "custom-body",
              templateName: "custom-body",
              body
            });
            return false;
          }
        }
        return true;
      });
    },

    toggleWhisper() {
      this.toggleProperty("model.whisper");
    },

    toggleInvisible() {
      this.toggleProperty("model.unlistTopic");
    },

    toggleToolbar() {
      this.toggleProperty("showToolbar");
    },

    // Toggle the reply view
    toggle() {
      this.closeAutocomplete();

      if (
        isEmpty(this.get("model.reply")) &&
        isEmpty(this.get("model.title"))
      ) {
        this.close();
      } else {
        if (
          this.get("model.composeState") === Composer.OPEN ||
          this.get("model.composeState") === Composer.FULLSCREEN
        ) {
          this.shrink();
        } else {
          this.cancelComposer();
        }
      }

      return false;
    },

    fullscreenComposer() {
      this.toggleFullscreen();
      return false;
    },

    // Import a quote from the post
    importQuote(toolbarEvent) {
      const postStream = this.get("topic.postStream");
      let postId = this.get("model.post.id");

      // If there is no current post, use the first post id from the stream
      if (!postId && postStream) {
        postId = postStream.get("stream.firstObject");
      }

      // If we're editing a post, fetch the reply when importing a quote
      if (this.get("model.editingPost")) {
        const replyToPostNumber = this.get("model.post.reply_to_post_number");
        if (replyToPostNumber) {
          const replyPost = postStream.posts.findBy(
            "post_number",
            replyToPostNumber
          );

          if (replyPost) {
            postId = replyPost.id;
          }
        }
      }

      if (postId) {
        this.set("model.loading", true);

        return this.store.find("post", postId).then(post => {
          const quote = buildQuote(post, post.raw, {
            full: true
          });

          toolbarEvent.addText(quote);
          this.set("model.loading", false);
        });
      }
    },

    cancel() {
      const differentDraftContext =
        this.get("topic.id") !== this.get("model.topic.id");
      this.cancelComposer(differentDraftContext);
    },

    save() {
      this.save();
    },

    displayEditReason() {
      this.set("showEditReason", true);
    },

    hitEsc() {
      if (
        document.querySelectorAll(".emoji-picker-modal.fadeIn").length === 1
      ) {
        this.appEvents.trigger("emoji-picker:close");
        return;
      }

      if ((this.messageCount || 0) > 0) {
        this.appEvents.trigger("composer-messages:close");
        return;
      }

      if (this.get("model.viewOpen") || this.get("model.viewFullscreen")) {
        this.shrink();
      }
    },

    openIfDraft() {
      if (this.get("model.viewDraft")) {
        this.set("model.composeState", Composer.OPEN);
      }
    },

    groupsMentioned(groups) {
      if (
        !this.get("model.creatingPrivateMessage") &&
        !this.get("model.topic.isPrivateMessage")
      ) {
        groups.forEach(group => {
          let body;
          const groupLink = Discourse.getURL(`/g/${group.name}/members`);

          if (group.max_mentions < group.user_count) {
            body = I18n.t("composer.group_mentioned_limit", {
              group: `@${group.name}`,
              max: group.max_mentions,
              group_link: groupLink
            });
          } else if (group.user_count > 0) {
            body = I18n.t("composer.group_mentioned", {
              group: `@${group.name}`,
              count: group.user_count,
              group_link: groupLink
            });
          }

          if (body) {
            this.appEvents.trigger("composer-messages:create", {
              extraClass: "custom-body",
              templateName: "custom-body",
              body
            });
          }
        });
      }
    },

    cannotSeeMention(mentions) {
      mentions.forEach(mention => {
        const translation = this.get("model.topic.isPrivateMessage")
          ? "composer.cannot_see_mention.private"
          : "composer.cannot_see_mention.category";
        const body = I18n.t(translation, {
          username: `@${mention.name}`
        });
        this.appEvents.trigger("composer-messages:create", {
          extraClass: "custom-body",
          templateName: "custom-body",
          body
        });
      });
    }
  },

  disableSubmit: or("model.loading", "isUploading"),

  save(force) {
    if (this.disableSubmit) return;

    // Clear the warning state if we're not showing the checkbox anymore
    if (!this.showWarning) {
      this.set("model.isWarning", false);
    }

    const composer = this.model;

    if (composer.cantSubmitPost) {
      this.set("lastValidatedAt", Date.now());
      return;
    }

    composer.set("disableDrafts", true);

    // for now handle a very narrow use case
    // if we are replying to a topic AND not on the topic pop the window up
    if (!force && composer.replyingToTopic) {
      const currentTopic = this.topicModel;

      if (!currentTopic) {
        this.save(true);
        return;
      }

      if (currentTopic.id !== composer.get("topic.id")) {
        const message = I18n.t("composer.posting_not_on_topic");

        let buttons = [
          {
            label: I18n.t("composer.cancel"),
            class: "d-modal-cancel",
            link: true
          }
        ];

        buttons.push({
          label:
            I18n.t("composer.reply_here") +
            "<br/><div class='topic-title overflow-ellipsis'>" +
            currentTopic.get("fancyTitle") +
            "</div>",
          class: "btn btn-reply-here",
          callback: () => {
            composer.setProperties({ topic: currentTopic, post: null });
            this.save(true);
          }
        });

        buttons.push({
          label:
            I18n.t("composer.reply_original") +
            "<br/><div class='topic-title overflow-ellipsis'>" +
            this.get("model.topic.fancyTitle") +
            "</div>",
          class: "btn-primary btn-reply-on-original",
          callback: () => this.save(true)
        });

        bootbox.dialog(message, buttons, { classes: "reply-where-modal" });
        return;
      }
    }

    var staged = false;

    // TODO: This should not happen in model
    const imageSizes = {};
    $("#reply-control .d-editor-preview img").each((i, e) => {
      const $img = $(e);
      const src = $img.prop("src");

      if (src && src.length) {
        imageSizes[src] = { width: $img.width(), height: $img.height() };
      }
    });

    const promise = composer
      .save({ imageSizes, editReason: this.editReason })
      .then(result => {
        if (result.responseJson.action === "enqueued") {
          this.send("postWasEnqueued", result.responseJson);
          if (result.responseJson.pending_post) {
            let pendingPosts = this.get("topicController.model.pending_posts");
            if (pendingPosts) {
              pendingPosts.pushObject(result.responseJson.pending_post);
            }
          }

          return this.destroyDraft().then(() => {
            this.close();
            this.appEvents.trigger("post-stream:refresh");
            return result;
          });
        }

        if (this.get("model.editingPost")) {
          this.appEvents.trigger("post-stream:refresh", {
            id: parseInt(result.responseJson.id, 10)
          });
          if (result.responseJson.post.post_number === 1) {
            this.appEvents.trigger("header:update-topic", composer.topic);
          }
        } else {
          this.appEvents.trigger("post-stream:refresh");
        }

        if (result.responseJson.action === "create_post") {
          this.appEvents.trigger("post:highlight", result.payload.post_number);
        }

        if (result.responseJson.route_to) {
          this.destroyDraft();
          if (result.responseJson.message) {
            return bootbox.alert(result.responseJson.message, () => {
              DiscourseURL.routeTo(result.responseJson.route_to);
            });
          }
          return DiscourseURL.routeTo(result.responseJson.route_to);
        }

        this.close();

        const currentUser = this.currentUser;
        if (composer.creatingTopic) {
          currentUser.set("topic_count", currentUser.topic_count + 1);
        } else {
          currentUser.set("reply_count", currentUser.reply_count + 1);
        }

        const post = result.target;
        if (post && !staged) {
          DiscourseURL.routeTo(post.url, { skipIfOnScreen: true });
        }
      })
      .catch(error => {
        composer.set("disableDrafts", false);
        if (error) {
          this.appEvents.one("composer:will-open", () => bootbox.alert(error));
        }
      });

    if (
      this.router.currentRouteName.split(".")[0] === "topic" &&
      composer.get("topic.id") === this.get("topicModel.id")
    ) {
      staged = composer.get("stagedPost");
    }

    this.appEvents.trigger("post-stream:posted", staged);

    this.messageBus.pause();
    promise.finally(() => this.messageBus.resume());

    return promise;
  },

  // Notify the composer messages controller that a reply has been typed. Some
  // messages only appear after typing.
  checkReplyLength() {
    if (!isEmpty("model.reply")) {
      this.appEvents.trigger("composer:typed-reply");
    }
  },

  /**
   Open the composer view

   @method open
   @param {Object} opts Options for creating a post
   @param {String} opts.action The action we're performing: edit, reply or createTopic
   @param {Post} [opts.post] The post we're replying to
   @param {Topic} [opts.topic] The topic we're replying to
   @param {String} [opts.quote] If we're opening a reply from a quote, the quote we're making
   **/
  open(opts) {
    opts = opts || {};

    if (!opts.draftKey) {
      throw new Error("composer opened without a proper draft key");
    }

    let composerModel = this.model;

    if (
      opts.ignoreIfChanged &&
      composerModel &&
      composerModel.composeState !== Composer.CLOSED
    ) {
      return;
    }

    this.setProperties({
      showEditReason: false,
      editReason: null,
      scopedCategoryId: null,
      skipAutoSave: true
    });

    // Scope the categories drop down to the category we opened the composer with.
    if (opts.categoryId && !opts.disableScopedCategory) {
      const category = this.site.categories.findBy("id", opts.categoryId);
      if (category) {
        this.set("scopedCategoryId", opts.categoryId);
      }
    }

    // If we want a different draft than the current composer, close it and clear our model.
    if (
      composerModel &&
      opts.draftKey !== composerModel.draftKey &&
      composerModel.composeState === Composer.DRAFT
    ) {
      this.close();
      composerModel = null;
    }

    let promise = new Promise((resolve, reject) => {
      if (composerModel && composerModel.replyDirty) {
        // If we're already open, we don't have to do anything
        if (
          composerModel.composeState === Composer.OPEN &&
          composerModel.draftKey === opts.draftKey &&
          !opts.action
        ) {
          return resolve();
        }

        // If it's the same draft, just open it up again.
        if (
          composerModel.composeState === Composer.DRAFT &&
          composerModel.draftKey === opts.draftKey
        ) {
          composerModel.set("composeState", Composer.OPEN);
          if (!opts.action) return resolve();
        }

        // If it's a different draft, cancel it and try opening again.
        const differentDraftContext =
          opts.post && composerModel.topic
            ? composerModel.topic.id !== opts.post.topic_id
            : true;

        return this.cancelComposer(differentDraftContext)
          .then(() => this.open(opts))
          .then(resolve, reject);
      }

      if (composerModel && composerModel.action !== opts.action) {
        composerModel.setProperties({ unlistTopic: false, whisper: false });
      }

      // we need a draft sequence for the composer to work
      if (opts.draftSequence === undefined) {
        return Draft.get(opts.draftKey)
          .then(data => {
            if (opts.skipDraftCheck) {
              data.draft = undefined;
              return data;
            }
            return this.confirmDraftAbandon(data);
          })
          .then(data => {
            if (!opts.draft && data.draft) {
              opts.draft = data.draft;
            }
            opts.draftSequence = data.draft_sequence;
            return this._setModel(composerModel, opts);
          })
          .then(resolve, reject);
      }
      // otherwise, do the draft check async
      else if (!opts.draft && !opts.skipDraftCheck) {
        Draft.get(opts.draftKey)
          .then(data => {
            return this.confirmDraftAbandon(data);
          })
          .then(data => {
            if (data.draft) {
              opts.draft = data.draft;
              opts.draftSequence = data.draft_sequence;
              return this.open(opts);
            }
          });
      }

      this._setModel(composerModel, opts).then(resolve, reject);
    });

    promise = promise.finally(() => {
      this.skipAutoSave = false;
    });
    return promise;
  },

  // Given a potential instance and options, set the model for this composer.
  _setModel(optionalComposerModel, opts) {
    let promise = Promise.resolve();

    this.set("linkLookup", null);

    promise = promise.then(() => {
      if (opts.draft) {
        return loadDraft(this.store, opts).then(model => {
          if (!model) {
            throw new Error("draft was not found");
          }
          return model;
        });
      } else {
        let model =
          optionalComposerModel || this.store.createRecord("composer");
        return model.open(opts).then(() => model);
      }
    });

    promise.then(composerModel => {
      this.set("model", composerModel);

      composerModel.setProperties({
        composeState: Composer.OPEN,
        isWarning: false
      });

      if (!this.model.targetRecipients) {
        if (opts.usernames) {
          deprecated("`usernames` is deprecated, use `recipients` instead.");
          this.model.set("targetRecipients", opts.usernames);
        } else if (opts.recipients) {
          this.model.set("targetRecipients", opts.recipients);
        }
      }

      if (
        opts.topicTitle &&
        opts.topicTitle.length <= this.siteSettings.max_topic_title_length
      ) {
        this.model.set("title", opts.topicTitle);
      }

      if (opts.topicCategoryId) {
        this.model.set("categoryId", opts.topicCategoryId);
      }

      if (opts.topicTags && !this.site.mobileView && this.site.can_tag_topics) {
        let tags = escapeExpression(opts.topicTags)
          .split(",")
          .slice(0, this.siteSettings.max_tags_per_topic);

        tags.forEach(
          (tag, index, array) =>
            (array[index] = tag.substring(0, this.siteSettings.max_tag_length))
        );

        this.model.set("tags", tags);
      }

      if (opts.topicBody) {
        this.model.set("reply", opts.topicBody);
      }
    });

    return promise;
  },

  viewNewReply() {
    DiscourseURL.routeTo(this.get("model.createdPost.url"));
    this.close();
    return false;
  },

  destroyDraft() {
    const key = this.get("model.draftKey");
    if (key) {
      if (key === "new_topic") {
        this.send("clearTopicDraft");
      }

      return Draft.clear(key, this.get("model.draftSequence")).then(() =>
        this.appEvents.trigger("draft:destroyed", key)
      );
    } else {
      return Promise.resolve();
    }
  },

  confirmDraftAbandon(data) {
    if (!data.draft) {
      return data;
    }

    // do not show abandon dialog if old draft is clean
    const draft = JSON.parse(data.draft);
    if (draft.reply === draft.originalText) {
      data.draft = null;
      return data;
    }

    if (_checkDraftPopup) {
      return new Promise(resolve => {
        bootbox.dialog(I18n.t("drafts.abandon.confirm"), [
          {
            label: I18n.t("drafts.abandon.no_value"),
            callback: () => resolve(data)
          },
          {
            label: I18n.t("drafts.abandon.yes_value"),
            class: "btn-danger",
            callback: () => {
              data.draft = null;
              resolve(data);
            }
          }
        ]);
      });
    } else {
      data.draft = null;
      return data;
    }
  },

  cancelComposer(differentDraft = false) {
    this.skipAutoSave = true;

    const keyPrefix =
      this.model.action === "edit" ? "post.abandon_edit" : "post.abandon";

    let promise = new Promise(resolve => {
      if (this.get("model.hasMetaData") || this.get("model.replyDirty")) {
        bootbox.dialog(I18n.t(keyPrefix + ".confirm"), [
          {
            label: differentDraft
              ? I18n.t(keyPrefix + ".no_save_draft")
              : I18n.t(keyPrefix + ".no_value"),
            callback: () => {
              // cancel composer without destroying draft on new draft context
              if (differentDraft) {
                this.model.clearState();
                this.close();
                resolve();
              }
            }
          },
          {
            label: I18n.t(keyPrefix + ".yes_value"),
            class: "btn-danger",
            callback: result => {
              if (result) {
                this.destroyDraft().then(() => {
                  this.model.clearState();
                  this.close();
                  resolve();
                });
              }
            }
          }
        ]);
      } else {
        // it is possible there is some sort of crazy draft with no body ... just give up on it
        this.destroyDraft().then(() => {
          this.model.clearState();
          this.close();
          resolve();
        });
      }
    });

    return promise.finally(() => {
      this.skipAutoSave = false;
    });
  },

  shrink() {
    if (
      this.get("model.replyDirty") ||
      (this.get("model.canEditTitle") && this.get("model.titleDirty"))
    ) {
      this.collapse();
    } else {
      this.close();
    }
  },

  _saveDraft() {
    const model = this.model;
    if (model) {
      model.saveDraft();
    }
  },

  @observes("model.reply", "model.title")
  _shouldSaveDraft() {
    if (
      this.model &&
      !this.model.loading &&
      !this.skipAutoSave &&
      !this.model.disableDrafts
    ) {
      debounce(this, this._saveDraft, 2000);
    }
  },

  @discourseComputed("model.categoryId", "lastValidatedAt")
  categoryValidation(categoryId, lastValidatedAt) {
    if (!this.siteSettings.allow_uncategorized_topics && !categoryId) {
      return EmberObject.create({
        failed: true,
        reason: I18n.t("composer.error.category_missing"),
        lastShownAt: lastValidatedAt
      });
    }
  },

  @discourseComputed("model.category", "model.tags", "lastValidatedAt")
  tagValidation(category, tags, lastValidatedAt) {
    const tagsArray = tags || [];
    if (
      this.site.can_tag_topics &&
      category &&
      category.minimum_required_tags > tagsArray.length
    ) {
      return EmberObject.create({
        failed: true,
        reason: I18n.t("composer.error.tags_missing", {
          count: category.minimum_required_tags
        }),
        lastShownAt: lastValidatedAt
      });
    }
  },

  collapse() {
    this._saveDraft();
    this.set("model.composeState", Composer.DRAFT);
  },

  toggleFullscreen() {
    this._saveDraft();
    if (this.get("model.composeState") === Composer.FULLSCREEN) {
      this.set("model.composeState", Composer.OPEN);
    } else {
      this.set("model.composeState", Composer.FULLSCREEN);
    }
  },

  close() {
    // the 'fullscreen-composer' class is added to remove scrollbars from the
    // document while in fullscreen mode. If the composer is closed for any reason
    // this class should be removed

    const elem = document.querySelector("html");
    elem.classList.remove("fullscreen-composer");

    this.setProperties({ model: null, lastValidatedAt: null });
  },

  closeAutocomplete() {
    $(".d-editor-input").autocomplete({ cancel: true });
  },

  @discourseComputed("model.action")
  canEdit(action) {
    return action === "edit" && this.currentUser.can_edit;
  },

  @discourseComputed("model.composeState")
  visible(state) {
    return state && state !== "closed";
  }
});
