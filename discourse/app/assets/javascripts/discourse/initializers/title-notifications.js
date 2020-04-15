export default {
  name: "title-notifications",
  after: "message-bus",

  initialize(container) {
    const user = container.lookup("current-user:main");
    if (!user) return; // must be logged in

    this.container = container;

    container
      .lookup("service:app-events")
      .on("notifications:changed", this, "_updateTitle");
  },

  _updateTitle() {
    const user = this.container.lookup("current-user:main");
    if (!user) return; // must be logged in

    const notifications =
      user.unread_notifications + user.unread_high_priority_notifications;

    Discourse.updateNotificationCount(notifications);
  }
};
