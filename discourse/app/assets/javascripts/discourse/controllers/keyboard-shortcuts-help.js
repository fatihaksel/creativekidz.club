import Controller from "@ember/controller";
import ModalFunctionality from "discourse/mixins/modal-functionality";
import { setting } from "discourse/lib/computed";

const KEY = "keyboard_shortcuts_help";

const SHIFT = I18n.t("shortcut_modifier_key.shift");
const ALT = I18n.t("shortcut_modifier_key.alt");
const CTRL = I18n.t("shortcut_modifier_key.ctrl");
const ENTER = I18n.t("shortcut_modifier_key.enter");

const COMMA = I18n.t(`${KEY}.shortcut_key_delimiter_comma`);
const PLUS = I18n.t(`${KEY}.shortcut_key_delimiter_plus`);

function buildHTML(keys1, keys2, keysDelimiter, shortcutsDelimiter) {
  const allKeys = [keys1, keys2]
    .reject(keys => keys.length === 0)
    .map(keys => keys.map(k => `<kbd>${k}</kbd>`).join(keysDelimiter))
    .map(keys => (shortcutsDelimiter !== "space" ? wrapInSpan(keys) : keys));

  const [shortcut1, shortcut2] = allKeys;

  if (allKeys.length === 1) {
    return shortcut1;
  } else if (shortcutsDelimiter === "or") {
    return I18n.t(`${KEY}.shortcut_delimiter_or`, { shortcut1, shortcut2 });
  } else if (shortcutsDelimiter === "slash") {
    return I18n.t(`${KEY}.shortcut_delimiter_slash`, { shortcut1, shortcut2 });
  } else if (shortcutsDelimiter === "space") {
    return wrapInSpan(
      I18n.t(`${KEY}.shortcut_delimiter_space`, { shortcut1, shortcut2 })
    );
  }
}

function wrapInSpan(shortcut) {
  return `<span dir="ltr">${shortcut}</span>`;
}

function buildShortcut(
  key,
  { keys1 = [], keys2 = [], keysDelimiter = COMMA, shortcutsDelimiter = "or" }
) {
  const context = {
    shortcut: buildHTML(keys1, keys2, keysDelimiter, shortcutsDelimiter)
  };
  return I18n.t(`${KEY}.${key}`, context);
}

export default Controller.extend(ModalFunctionality, {
  onShow() {
    this.set("modal.modalClass", "keyboard-shortcuts-modal");
    this._defineShortcuts();
  },

  onClose() {
    this.set("shortcuts", null);
  },

  showBookmarkShortcuts: setting("enable_bookmarks_with_reminders"),

  _defineShortcuts() {
    this.set("shortcuts", {
      jump_to: {
        home: buildShortcut("jump_to.home", { keys1: ["g", "h"] }),
        latest: buildShortcut("jump_to.latest", { keys1: ["g", "l"] }),
        new: buildShortcut("jump_to.new", { keys1: ["g", "n"] }),
        unread: buildShortcut("jump_to.unread", { keys1: ["g", "u"] }),
        categories: buildShortcut("jump_to.categories", { keys1: ["g", "c"] }),
        top: buildShortcut("jump_to.top", { keys1: ["g", "t"] }),
        bookmarks: buildShortcut("jump_to.bookmarks", { keys1: ["g", "b"] }),
        profile: buildShortcut("jump_to.profile", { keys1: ["g", "p"] }),
        messages: buildShortcut("jump_to.messages", { keys1: ["g", "m"] }),
        drafts: buildShortcut("jump_to.drafts", { keys1: ["g", "d"] })
      },
      navigation: {
        back: buildShortcut("navigation.back", { keys1: ["u"] }),
        jump: buildShortcut("navigation.jump", { keys1: ["#"] }),
        up_down: buildShortcut("navigation.up_down", {
          keys1: ["k"],
          keys2: ["j"],
          shortcutsDelimiter: "slash"
        }),
        open: buildShortcut("navigation.open", {
          keys1: ["o"],
          keys2: [ENTER]
        }),
        next_prev: buildShortcut("navigation.next_prev", {
          keys1: [SHIFT, "j"],
          keys2: [SHIFT, "k"],
          keysDelimiter: PLUS,
          shortcutsDelimiter: "slash"
        }),
        go_to_unread_post: buildShortcut("navigation.go_to_unread_post", {
          keys1: [SHIFT, "l"],
          keysDelimiter: PLUS
        })
      },
      application: {
        hamburger_menu: buildShortcut("application.hamburger_menu", {
          keys1: ["="]
        }),
        user_profile_menu: buildShortcut("application.user_profile_menu", {
          keys1: ["p"]
        }),
        create: buildShortcut("application.create", { keys1: ["c"] }),
        show_incoming_updated_topics: buildShortcut(
          "application.show_incoming_updated_topics",
          { keys1: ["."] }
        ),
        search: buildShortcut("application.search", {
          keys1: ["/"],
          keys2: [CTRL, ALT, "f"],
          keysDelimiter: PLUS
        }),
        help: buildShortcut("application.help", { keys1: ["?"] }),
        dismiss_new_posts: buildShortcut("application.dismiss_new_posts", {
          keys1: ["x", "r"]
        }),
        dismiss_topics: buildShortcut("application.dismiss_topics", {
          keys1: ["x", "t"]
        }),
        log_out: buildShortcut("application.log_out", {
          keys1: [SHIFT, "z"],
          keys2: [SHIFT, "z"],
          keysDelimiter: PLUS,
          shortcutsDelimiter: "space"
        })
      },
      composing: {
        return: buildShortcut("composing.return", {
          keys1: [SHIFT, "c"],
          keysDelimiter: PLUS
        }),
        fullscreen: buildShortcut("composing.fullscreen", {
          keys1: [SHIFT, "F11"],
          keysDelimiter: PLUS
        })
      },
      bookmarks: {
        enter: buildShortcut("bookmarks.enter", { keys1: [ENTER] }),
        later_today: buildShortcut("bookmarks.later_today", {
          keys1: ["l", "t"],
          shortcutsDelimiter: "space"
        }),
        later_this_week: buildShortcut("bookmarks.later_this_week", {
          keys1: ["l", "w"],
          shortcutsDelimiter: "space"
        }),
        tomorrow: buildShortcut("bookmarks.tomorrow", {
          keys1: ["n", "d"],
          shortcutsDelimiter: "space"
        }),
        next_week: buildShortcut("bookmarks.next_week", {
          keys1: ["n", "w"],
          shortcutsDelimiter: "space"
        }),
        next_business_week: buildShortcut("bookmarks.next_business_week", {
          keys1: ["n", "b", "w"],
          shortcutsDelimiter: "space"
        }),
        next_business_day: buildShortcut("bookmarks.next_business_day", {
          keys1: ["n", "b", "d"],
          shortcutsDelimiter: "space"
        }),
        custom: buildShortcut("bookmarks.custom", {
          keys1: ["c", "r"],
          shortcutsDelimiter: "space"
        }),
        none: buildShortcut("bookmarks.none", {
          keys1: ["n", "r"],
          shortcutsDelimiter: "space"
        })
      },
      actions: {
        bookmark_topic: buildShortcut("actions.bookmark_topic", {
          keys1: ["f"]
        }),
        reply_as_new_topic: buildShortcut("actions.reply_as_new_topic", {
          keys1: ["t"]
        }),
        reply_topic: buildShortcut("actions.reply_topic", {
          keys1: [SHIFT, "r"],
          keysDelimiter: PLUS
        }),
        reply_post: buildShortcut("actions.reply_post", { keys1: ["r"] }),
        quote_post: buildShortcut("actions.quote_post", { keys1: ["q"] }),
        pin_unpin_topic: buildShortcut("actions.pin_unpin_topic", {
          keys1: [SHIFT, "p"],
          keysDelimiter: PLUS
        }),
        share_topic: buildShortcut("actions.share_topic", {
          keys1: [SHIFT, "s"],
          keysDelimiter: PLUS
        }),
        share_post: buildShortcut("actions.share_post", { keys1: ["s"] }),
        like: buildShortcut("actions.like", { keys1: ["l"] }),
        flag: buildShortcut("actions.flag", { keys1: ["!"] }),
        bookmark: buildShortcut("actions.bookmark", { keys1: ["b"] }),
        edit: buildShortcut("actions.edit", { keys1: ["e"] }),
        delete: buildShortcut("actions.delete", { keys1: ["d"] }),
        mark_muted: buildShortcut("actions.mark_muted", { keys1: ["m", "m"] }),
        mark_regular: buildShortcut("actions.mark_regular", {
          keys1: ["m", "r"]
        }),
        mark_tracking: buildShortcut("actions.mark_tracking", {
          keys1: ["m", "t"]
        }),
        mark_watching: buildShortcut("actions.mark_watching", {
          keys1: ["m", "w"]
        }),
        print: buildShortcut("actions.print", {
          keys1: [CTRL, "p"],
          keysDelimiter: PLUS
        }),
        defer: buildShortcut("actions.defer", {
          keys1: [SHIFT, "u"],
          keysDelimiter: PLUS
        }),
        topic_admin_actions: buildShortcut("actions.topic_admin_actions", {
          keys1: [SHIFT, "a"],
          keysDelimiter: PLUS
        })
      },
      search_menu: {
        prev_next: buildShortcut("search_menu.prev_next", {
          keys1: ["&uarr;"],
          keys2: ["&darr;"],
          shortcutsDelimiter: "slash"
        }),
        insert_url: buildShortcut("search_menu.insert_url", {
          keys1: ["a"]
        })
      }
    });
  }
});
