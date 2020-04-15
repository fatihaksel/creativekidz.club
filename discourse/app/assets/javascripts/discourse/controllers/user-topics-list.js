import discourseComputed, { observes } from "discourse-common/utils/decorators";
import Controller, { inject as controller } from "@ember/controller";

// Lists of topics on a user's page.
export default Controller.extend({
  application: controller(),

  hideCategory: false,
  showPosters: false,
  incomingCount: 0,
  channel: null,
  tagsForUser: null,

  init() {
    this._super(...arguments);

    this.newIncoming = [];
  },

  saveScrollPosition: function() {
    this.session.set("topicListScrollPosition", $(window).scrollTop());
  },

  @observes("model.canLoadMore")
  _showFooter: function() {
    this.set("application.showFooter", !this.get("model.canLoadMore"));
  },

  @discourseComputed("incomingCount")
  hasIncoming(incomingCount) {
    return incomingCount > 0;
  },

  subscribe(channel) {
    this.set("channel", channel);

    this.messageBus.subscribe(channel, data => {
      if (this.newIncoming.indexOf(data.topic_id) === -1) {
        this.newIncoming.push(data.topic_id);
        this.incrementProperty("incomingCount");
      }
    });
  },

  unsubscribe() {
    const channel = this.channel;
    if (channel) this.messageBus.unsubscribe(channel);
    this._resetTracking();
    this.set("channel", null);
  },

  _resetTracking() {
    this.setProperties({
      newIncoming: [],
      incomingCount: 0
    });
  },

  actions: {
    loadMore: function() {
      this.model.loadMore();
    },

    showInserted() {
      this.model.loadBefore(this.newIncoming);
      this._resetTracking();
      return false;
    }
  }
});
