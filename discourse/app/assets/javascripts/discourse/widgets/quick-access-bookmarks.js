import { h } from "virtual-dom";
import QuickAccessPanel from "discourse/widgets/quick-access-panel";
import UserAction from "discourse/models/user-action";
import { ajax } from "discourse/lib/ajax";
import { createWidgetFrom } from "discourse/widgets/widget";
import { postUrl } from "discourse/lib/utilities";

const ICON = "bookmark";

createWidgetFrom(QuickAccessPanel, "quick-access-bookmarks", {
  buildKey: () => "quick-access-bookmarks",

  hasMore() {
    // Always show the button to the bookmarks page.
    return true;
  },

  showAllHref() {
    if (this.siteSettings.enable_bookmarks_with_reminders) {
      return `${this.attrs.path}/activity/bookmarks-with-reminders`;
    } else {
      return `${this.attrs.path}/activity/bookmarks`;
    }
  },

  emptyStatePlaceholderItem() {
    return h("li.read", this.state.emptyStatePlaceholderItemText);
  },

  findNewItems() {
    if (this.siteSettings.enable_bookmarks_with_reminders) {
      return this.loadBookmarksWithReminders();
    } else {
      return this.loadUserActivityBookmarks();
    }
  },

  itemHtml(bookmark) {
    return this.attach("quick-access-item", {
      icon: this.icon(bookmark),
      href: postUrl(
        bookmark.slug,
        bookmark.topic_id,
        bookmark.post_number || bookmark.linked_post_number
      ),
      content: bookmark.title,
      username: bookmark.username
    });
  },

  icon(bookmark) {
    if (bookmark.reminder_at) {
      return "discourse-bookmark-clock";
    }
    return ICON;
  },

  loadBookmarksWithReminders() {
    return ajax(`/u/${this.currentUser.username}/bookmarks.json`, {
      cache: "false",
      data: {
        limit: this.estimateItemLimit()
      }
    }).then(result => {
      result = result.user_bookmark_list;

      // The empty state help text for bookmarks page is localized on the
      // server.
      if (result.no_results_help) {
        this.state.emptyStatePlaceholderItemText = result.no_results_help;
      }
      return result.bookmarks;
    });
  },

  loadUserActivityBookmarks() {
    return ajax("/user_actions.json", {
      cache: "false",
      data: {
        username: this.currentUser.username,
        filter: UserAction.TYPES.bookmarks,
        limit: this.estimateItemLimit(),
        no_results_help_key: "user_activity.no_bookmarks"
      }
    }).then(({ user_actions, no_results_help }) => {
      // The empty state help text for bookmarks page is localized on the
      // server.
      this.state.emptyStatePlaceholderItemText = no_results_help;
      return user_actions;
    });
  }
});
