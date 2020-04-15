import PostCooked from "discourse/widgets/post-cooked";
import DecoratorHelper from "discourse/widgets/decorator-helper";
import { createWidget, applyDecorators } from "discourse/widgets/widget";
import RawHtml from "discourse/widgets/raw-html";
import { iconNode } from "discourse-common/lib/icon-library";
import { transformBasicPost } from "discourse/lib/transform-post";
import { postTransformCallbacks } from "discourse/widgets/post-stream";
import { h } from "virtual-dom";
import DiscourseURL from "discourse/lib/url";
import { dateNode } from "discourse/helpers/node";
import {
  translateSize,
  avatarUrl,
  formatUsername
} from "discourse/lib/utilities";
import hbs from "discourse/widgets/hbs-compiler";
import { relativeAgeMediumSpan } from "discourse/lib/formatter";
import { prioritizeNameInUx } from "discourse/lib/settings";
import { Promise } from "rsvp";

function transformWithCallbacks(post) {
  let transformed = transformBasicPost(post);
  postTransformCallbacks(transformed);
  return transformed;
}

export function avatarImg(wanted, attrs) {
  const size = translateSize(wanted);
  const url = avatarUrl(attrs.template, size);

  // We won't render an invalid url
  if (!url || url.length === 0) {
    return;
  }
  const title = attrs.name || formatUsername(attrs.username);

  let className =
    "avatar" + (attrs.extraClasses ? " " + attrs.extraClasses : "");

  const properties = {
    attributes: {
      alt: "",
      width: size,
      height: size,
      src: Discourse.getURLWithCDN(url),
      title
    },
    className
  };

  return h("img", properties);
}

export function avatarFor(wanted, attrs) {
  return h(
    "a",
    {
      className: `trigger-user-card ${attrs.className || ""}`,
      attributes: { href: attrs.url, "data-user-card": attrs.username }
    },
    avatarImg(wanted, attrs)
  );
}

// TODO: Improve how helpers are registered for vdom compliation
if (typeof Discourse !== "undefined") {
  Discourse.__widget_helpers.avatar = avatarFor;
}

createWidget("select-post", {
  tagName: "div.select-posts",

  html(attrs) {
    const buttons = [];

    if (!attrs.selected && attrs.post_number > 1) {
      if (attrs.replyCount > 0) {
        buttons.push(
          this.attach("button", {
            label: "topic.multi_select.select_replies.label",
            title: "topic.multi_select.select_replies.title",
            action: "selectReplies",
            className: "select-replies"
          })
        );
      }
      buttons.push(
        this.attach("button", {
          label: "topic.multi_select.select_below.label",
          title: "topic.multi_select.select_below.title",
          action: "selectBelow",
          className: "select-below"
        })
      );
    }

    const key = `topic.multi_select.${
      attrs.selected ? "selected" : "select"
    }_post`;
    buttons.push(
      this.attach("button", {
        label: key + ".label",
        title: key + ".title",
        action: "togglePostSelection",
        className: "select-post"
      })
    );

    return buttons;
  }
});

createWidget("reply-to-tab", {
  tagName: "a.reply-to-tab",
  buildKey: attrs => `reply-to-tab-${attrs.id}`,

  defaultState() {
    return { loading: false };
  },

  html(attrs, state) {
    if (state.loading) {
      return I18n.t("loading");
    }

    return [
      iconNode("share"),
      " ",
      avatarImg("small", {
        template: attrs.replyToAvatarTemplate,
        username: attrs.replyToUsername
      }),
      " ",
      h("span", formatUsername(attrs.replyToUsername))
    ];
  },

  click() {
    this.state.loading = true;
    this.sendWidgetAction("toggleReplyAbove").then(
      () => (this.state.loading = false)
    );
  }
});

createWidget("post-avatar-user-info", {
  tagName: "div.post-avatar-user-info",

  html(attrs) {
    return this.attach("poster-name", attrs);
  }
});

createWidget("post-avatar", {
  tagName: "div.topic-avatar",

  settings: {
    size: "large",
    displayPosterName: false
  },

  html(attrs) {
    let body;
    if (!attrs.user_id) {
      body = iconNode("far-trash-alt", { class: "deleted-user-avatar" });
    } else {
      body = avatarFor.call(this, this.settings.size, {
        template: attrs.avatar_template,
        username: attrs.username,
        name: attrs.name,
        url: attrs.usernameUrl,
        className: "main-avatar"
      });
    }

    const result = [body];

    if (attrs.primary_group_flair_url || attrs.primary_group_flair_bg_color) {
      result.push(this.attach("avatar-flair", attrs));
    }

    result.push(h("div.poster-avatar-extra"));

    if (this.settings.displayPosterName) {
      result.push(this.attach("post-avatar-user-info", attrs));
    }

    return result;
  }
});

createWidget("post-locked-indicator", {
  tagName: "div.post-info.post-locked",
  template: hbs`{{d-icon "lock"}}`,
  title: () => I18n.t("post.locked")
});

createWidget("post-email-indicator", {
  tagName: "div.post-info.via-email",

  title(attrs) {
    return attrs.isAutoGenerated
      ? I18n.t("post.via_auto_generated_email")
      : I18n.t("post.via_email");
  },

  buildClasses(attrs) {
    return attrs.canViewRawEmail ? "raw-email" : null;
  },

  html(attrs) {
    return attrs.isAutoGenerated
      ? iconNode("envelope")
      : iconNode("far-envelope");
  },

  click() {
    if (this.attrs.canViewRawEmail) {
      this.sendWidgetAction("showRawEmail");
    }
  }
});

function showReplyTab(attrs, siteSettings) {
  return (
    attrs.replyToUsername &&
    (!attrs.replyDirectlyAbove || !siteSettings.suppress_reply_directly_above)
  );
}

createWidget("post-meta-data", {
  tagName: "div.topic-meta-data",

  settings: {
    displayPosterName: true
  },

  html(attrs) {
    let postInfo = [];

    if (attrs.isWhisper) {
      postInfo.push(
        h(
          "div.post-info.whisper",
          {
            attributes: { title: I18n.t("post.whisper") }
          },
          iconNode("far-eye-slash")
        )
      );
    }

    const lastWikiEdit =
      attrs.wiki && attrs.lastWikiEdit && new Date(attrs.lastWikiEdit);
    const createdAt = new Date(attrs.created_at);
    const date = lastWikiEdit ? dateNode(lastWikiEdit) : dateNode(createdAt);
    const attributes = {
      class: "post-date",
      href: attrs.shareUrl,
      "data-share-url": attrs.shareUrl,
      "data-post-number": attrs.post_number
    };

    if (lastWikiEdit) {
      attributes["class"] += " last-wiki-edit";
    }

    if (attrs.via_email) {
      postInfo.push(this.attach("post-email-indicator", attrs));
    }

    if (attrs.locked) {
      postInfo.push(this.attach("post-locked-indicator", attrs));
    }

    if (attrs.version > 1 || attrs.wiki) {
      postInfo.push(this.attach("post-edits-indicator", attrs));
    }

    if (attrs.multiSelect) {
      postInfo.push(this.attach("select-post", attrs));
    }

    if (showReplyTab(attrs, this.siteSettings)) {
      postInfo.push(this.attach("reply-to-tab", attrs));
    }

    postInfo.push(h("div.post-info.post-date", h("a", { attributes }, date)));

    postInfo.push(
      h(
        "div.read-state",
        {
          className: attrs.read ? "read" : null,
          attributes: {
            title: I18n.t("post.unread")
          }
        },
        iconNode("circle")
      )
    );

    let result = [];
    if (this.settings.displayPosterName) {
      result.push(this.attach("poster-name", attrs));
    }
    result.push(h("div.post-infos", postInfo));

    return result;
  }
});

createWidget("expand-hidden", {
  tagName: "a.expand-hidden",

  html() {
    return I18n.t("post.show_hidden");
  },

  click() {
    this.sendWidgetAction("expandHidden");
  }
});

createWidget("expand-post-button", {
  tagName: "button.btn.expand-post",
  buildKey: attrs => `expand-post-button-${attrs.id}`,

  defaultState() {
    return { loadingExpanded: false };
  },

  html(attrs, state) {
    if (state.loadingExpanded) {
      return I18n.t("loading");
    } else {
      return [I18n.t("post.show_full"), "..."];
    }
  },

  click() {
    this.state.loadingExpanded = true;
    this.sendWidgetAction("expandFirstPost");
  }
});

createWidget("post-group-request", {
  buildKey: attrs => `post-group-request-${attrs.id}`,

  buildClasses() {
    return ["group-request"];
  },

  html(attrs) {
    const href = Discourse.getURL(
      "/g/" + attrs.requestedGroupName + "/requests?filter=" + attrs.username
    );

    return h("a", { attributes: { href } }, I18n.t("groups.requests.handle"));
  }
});

createWidget("post-contents", {
  buildKey: attrs => `post-contents-${attrs.id}`,

  defaultState() {
    return { expandedFirstPost: false, repliesBelow: [] };
  },

  buildClasses(attrs) {
    const classes = ["regular"];
    if (!this.state.repliesShown) {
      classes.push("contents");
    }
    if (showReplyTab(attrs, this.siteSettings)) {
      classes.push("avoid-tab");
    }
    return classes;
  },

  html(attrs, state) {
    let result = [
      new PostCooked(attrs, new DecoratorHelper(this), this.currentUser)
    ];

    if (attrs.requestedGroupName) {
      result.push(this.attach("post-group-request", attrs));
    }

    result = result.concat(applyDecorators(this, "after-cooked", attrs, state));

    if (attrs.cooked_hidden) {
      result.push(this.attach("expand-hidden", attrs));
    }

    if (!state.expandedFirstPost && attrs.expandablePost) {
      result.push(this.attach("expand-post-button", attrs));
    }

    const extraState = { state: { repliesShown: !!state.repliesBelow.length } };
    result.push(this.attach("post-menu", attrs, extraState));

    const repliesBelow = state.repliesBelow;
    if (repliesBelow.length) {
      result.push(
        h("section.embedded-posts.bottom", [
          repliesBelow.map(p => {
            return this.attach("embedded-post", p, {
              model: this.store.createRecord("post", p)
            });
          }),
          this.attach("button", {
            title: "post.collapse",
            icon: "chevron-up",
            action: "toggleRepliesBelow",
            actionParam: "true",
            className: "btn collapse-up"
          })
        ])
      );
    }

    return result;
  },

  _date(attrs) {
    const lastWikiEdit =
      attrs.wiki && attrs.lastWikiEdit && new Date(attrs.lastWikiEdit);
    const createdAt = new Date(attrs.created_at);
    return lastWikiEdit ? lastWikiEdit : createdAt;
  },

  toggleRepliesBelow(goToPost = "false") {
    if (this.state.repliesBelow.length) {
      this.state.repliesBelow = [];
      if (goToPost === "true") {
        DiscourseURL.routeTo(
          `${this.attrs.topicUrl}/${this.attrs.post_number}`
        );
      }
      return;
    }

    const post = this.findAncestorModel();
    const topicUrl = post ? post.get("topic.url") : null;
    return this.store
      .find("post-reply", { postId: this.attrs.id })
      .then(posts => {
        this.state.repliesBelow = posts.map(p => {
          p.shareUrl = `${topicUrl}/${p.post_number}`;
          return transformWithCallbacks(p);
        });
      });
  },

  expandFirstPost() {
    const post = this.findAncestorModel();
    return post.expand().then(() => (this.state.expandedFirstPost = true));
  }
});

createWidget("post-notice", {
  tagName: "div.post-notice",

  buildClasses(attrs) {
    const classes = [attrs.noticeType.replace(/_/g, "-")];

    if (
      new Date() - new Date(attrs.created_at) >
      this.siteSettings.old_post_notice_days * 86400000
    ) {
      classes.push("old");
    }

    return classes;
  },

  html(attrs) {
    const user =
      this.siteSettings.display_name_on_posts && prioritizeNameInUx(attrs.name)
        ? attrs.name
        : attrs.username;
    let text, icon;
    if (attrs.noticeType === "custom") {
      icon = "user-shield";
      text = new RawHtml({ html: `<div>${attrs.noticeMessage}</div>` });
    } else if (attrs.noticeType === "new_user") {
      icon = "hands-helping";
      text = h("p", I18n.t("post.notice.new_user", { user }));
    } else if (attrs.noticeType === "returning_user") {
      icon = "far-smile";
      const distance = (new Date() - new Date(attrs.noticeTime)) / 1000;
      text = h(
        "p",
        I18n.t("post.notice.returning_user", {
          user,
          time: relativeAgeMediumSpan(distance, true)
        })
      );
    }

    return [iconNode(icon), text];
  }
});

createWidget("post-body", {
  tagName: "div.topic-body.clearfix",

  html(attrs, state) {
    const postContents = this.attach("post-contents", attrs);
    let result = [this.attach("post-meta-data", attrs)];
    result = result.concat(
      applyDecorators(this, "after-meta-data", attrs, state)
    );
    result.push(postContents);
    result.push(this.attach("actions-summary", attrs));
    result.push(this.attach("post-links", attrs));
    if (attrs.showTopicMap) {
      result.push(this.attach("topic-map", attrs));
    }

    return result;
  }
});

createWidget("post-article", {
  tagName: "article.boxed.onscreen-post",
  buildKey: attrs => `post-article-${attrs.id}`,

  defaultState() {
    return { repliesAbove: [] };
  },

  buildId(attrs) {
    return `post_${attrs.post_number}`;
  },

  buildClasses(attrs) {
    let classNames = [];
    if (attrs.via_email) {
      classNames.push("via-email");
    }
    if (attrs.isAutoGenerated) {
      classNames.push("is-auto-generated");
    }
    return classNames;
  },

  buildAttributes(attrs) {
    return {
      "data-post-id": attrs.id,
      "data-topic-id": attrs.topicId,
      "data-user-id": attrs.user_id
    };
  },

  html(attrs, state) {
    const rows = [
      h("a.tabLoc", { attributes: { href: "", "aria-hidden": true } })
    ];
    if (state.repliesAbove.length) {
      const replies = state.repliesAbove.map(p => {
        return this.attach("embedded-post", p, {
          model: this.store.createRecord("post", p),
          state: { above: true }
        });
      });

      rows.push(
        h(
          "div.row",
          h("section.embedded-posts.top.topic-body", [
            this.attach("button", {
              title: "post.collapse",
              icon: "chevron-down",
              action: "toggleReplyAbove",
              actionParam: "true",
              className: "btn collapse-down"
            }),
            replies
          ])
        )
      );
    }

    if (attrs.noticeType) {
      rows.push(h("div.row", [this.attach("post-notice", attrs)]));
    }

    rows.push(
      h("div.row", [
        this.attach("post-avatar", attrs),
        this.attach("post-body", attrs)
      ])
    );
    return rows;
  },

  _getTopicUrl() {
    const post = this.findAncestorModel();
    return post ? post.get("topic.url") : null;
  },

  toggleReplyAbove(goToPost = "false") {
    const replyPostNumber = this.attrs.reply_to_post_number;

    // jump directly on mobile
    if (this.attrs.mobileView) {
      const topicUrl = this._getTopicUrl();
      if (topicUrl) {
        DiscourseURL.routeTo(`${topicUrl}/${replyPostNumber}`);
      }
      return Promise.resolve();
    }

    if (this.state.repliesAbove.length) {
      this.state.repliesAbove = [];
      if (goToPost === "true") {
        DiscourseURL.routeTo(
          `${this.attrs.topicUrl}/${this.attrs.post_number}`
        );
      }
      return Promise.resolve();
    } else {
      const topicUrl = this._getTopicUrl();
      return this.store
        .find("post-reply-history", { postId: this.attrs.id })
        .then(posts => {
          this.state.repliesAbove = posts.map(p => {
            p.shareUrl = `${topicUrl}/${p.post_number}`;
            return transformWithCallbacks(p);
          });
        });
    }
  }
});

let addPostClassesCallbacks = null;
export function addPostClassesCallback(callback) {
  addPostClassesCallbacks = addPostClassesCallbacks || [];
  addPostClassesCallbacks.push(callback);
}

export default createWidget("post", {
  buildKey: attrs => `post-${attrs.id}`,
  shadowTree: true,

  buildAttributes(attrs) {
    return attrs.height
      ? { style: `min-height: ${attrs.height}px` }
      : undefined;
  },

  buildId(attrs) {
    return attrs.cloaked ? `post_${attrs.post_number}` : undefined;
  },

  buildClasses(attrs) {
    if (attrs.cloaked) {
      return "cloaked-post";
    }
    const classNames = ["topic-post", "clearfix"];

    if (attrs.id === -1 || attrs.isSaving) {
      classNames.push("staged");
    }
    if (attrs.selected) {
      classNames.push("selected");
    }
    if (attrs.topicOwner) {
      classNames.push("topic-owner");
    }
    if (attrs.hidden) {
      classNames.push("post-hidden");
    }
    if (attrs.deleted) {
      classNames.push("deleted");
    }
    if (attrs.primary_group_name) {
      classNames.push(`group-${attrs.primary_group_name}`);
    }
    if (attrs.wiki) {
      classNames.push(`wiki`);
    }
    if (attrs.isWhisper) {
      classNames.push("whisper");
    }
    if (attrs.isModeratorAction || (attrs.isWarning && attrs.firstPost)) {
      classNames.push("moderator");
    } else {
      classNames.push("regular");
    }
    if (addPostClassesCallbacks) {
      for (let i = 0; i < addPostClassesCallbacks.length; i++) {
        let pluginClasses = addPostClassesCallbacks[i].call(this, attrs);
        if (pluginClasses) {
          classNames.push.apply(classNames, pluginClasses);
        }
      }
    }
    return classNames;
  },

  html(attrs) {
    if (attrs.cloaked) {
      return "";
    }

    return this.attach("post-article", attrs);
  },

  toggleLike() {
    const post = this.model;
    const likeAction = post.get("likeAction");

    if (likeAction && likeAction.get("canToggle")) {
      return likeAction.togglePromise(post).then(result => {
        this.appEvents.trigger("page:like-toggled", post, likeAction);
        return this._warnIfClose(result);
      });
    }
  },

  _warnIfClose(result) {
    if (!result || !result.acted) {
      return;
    }

    const kvs = this.keyValueStore;
    const lastWarnedLikes = kvs.get("lastWarnedLikes");

    // only warn once per day
    const yesterday = Date.now() - 1000 * 60 * 60 * 24;
    if (lastWarnedLikes && parseInt(lastWarnedLikes, 10) > yesterday) {
      return;
    }

    const { remaining, max } = result;
    const threshold = Math.ceil(max * 0.1);
    if (remaining === threshold) {
      bootbox.alert(I18n.t("post.few_likes_left"));
      kvs.set({ key: "lastWarnedLikes", value: Date.now() });
    }
  }
});
