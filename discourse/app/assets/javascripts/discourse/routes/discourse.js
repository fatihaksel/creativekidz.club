import { once } from "@ember/runloop";
import Composer from "discourse/models/composer";
import { getOwner } from "discourse-common/lib/get-owner";
import Route from "@ember/routing/route";
import deprecated from "discourse-common/lib/deprecated";
import { seenUser } from "discourse/lib/user-presence";

const DiscourseRoute = Route.extend({
  showFooter: false,

  willTransition() {
    seenUser();
  },

  // Set to true to refresh a model without a transition if a query param
  // changes
  resfreshQueryWithoutTransition: false,

  activate() {
    this._super(...arguments);
    if (this.showFooter) {
      this.controllerFor("application").set("showFooter", true);
    }
  },

  refresh() {
    if (!this.refreshQueryWithoutTransition) {
      return this._super(...arguments);
    }

    const router = getOwner(this).lookup("router:main");
    if (!router._routerMicrolib.activeTransition) {
      const controller = this.controller,
        model = controller.get("model"),
        params = this.controller.getProperties(Object.keys(this.queryParams));

      model.set("loading", true);
      this.model(params).then(m => this.setupController(controller, m));
    }
  },

  _refreshTitleOnce() {
    this.send("_collectTitleTokens", []);
  },

  actions: {
    _collectTitleTokens(tokens) {
      // If there's a title token method, call it and get the token
      if (this.titleToken) {
        const t = this.titleToken();
        if (t && t.length) {
          if (t instanceof Array) {
            t.forEach(function(ti) {
              tokens.push(ti);
            });
          } else {
            tokens.push(t);
          }
        }
      }
      return true;
    },

    refreshTitle() {
      once(this, this._refreshTitleOnce);
    },

    clearTopicDraft() {
      // perhaps re-delegate this to root controller in all cases?
      // TODO also poison the store so it does not come back from the
      // dead
      if (this.get("controller.list.draft")) {
        this.set("controller.list.draft", null);
      }

      if (this.controllerFor("discovery/categories").get("model.draft")) {
        this.controllerFor("discovery/categories").set("model.draft", null);
      }

      if (this.controllerFor("discovery/topics").get("model.draft")) {
        this.controllerFor("discovery/topics").set("model.draft", null);
      }
    }
  },

  redirectIfLoginRequired() {
    const app = this.controllerFor("application");
    if (app.get("loginRequired")) {
      this.replaceWith("login");
    }
  },

  openTopicDraft(model) {
    const composer = this.controllerFor("composer");

    if (
      composer.get("model.action") === Composer.CREATE_TOPIC &&
      composer.get("model.draftKey") === model.draft_key
    ) {
      composer.set("model.composeState", Composer.OPEN);
    } else {
      composer.open({
        action: Composer.CREATE_TOPIC,
        draft: model.draft,
        draftKey: model.draft_key,
        draftSequence: model.draft_sequence
      });
    }
  },

  isPoppedState(transition) {
    return !transition._discourse_intercepted && !!transition.intent.url;
  }
});

Object.defineProperty(Discourse, "Route", {
  get() {
    deprecated("Import the Route class instead of using Discourse.Route", {
      since: "2.4.0",
      dropFrom: "2.5.0"
    });
    return Route;
  }
});

export default DiscourseRoute;
