import { gt, and } from "@ember/object/computed";
import { schedule } from "@ember/runloop";
import Component from "@ember/component";
import discourseComputed, { observes } from "discourse-common/utils/decorators";
import { iconHTML } from "discourse-common/lib/icon-library";
import { escape } from "pretty-text/sanitizer";
import ENV from "discourse-common/config/environment";

const MAX_COMPONENTS = 4;

export default Component.extend({
  childrenExpanded: false,
  classNames: ["themes-list-item"],
  classNameBindings: ["theme.selected:selected"],
  hasComponents: gt("children.length", 0),
  displayComponents: and("hasComponents", "theme.isActive"),
  displayHasMore: gt("theme.childThemes.length", MAX_COMPONENTS),

  click(e) {
    if (!$(e.target).hasClass("others-count")) {
      this.navigateToTheme();
    }
  },

  init() {
    this._super(...arguments);
    this.scheduleAnimation();
  },

  @observes("theme.selected")
  triggerAnimation() {
    this.animate();
  },

  scheduleAnimation() {
    schedule("afterRender", () => {
      this.animate(true);
    });
  },

  animate(isInitial) {
    const $container = $(this.element);
    const $list = $(this.element.querySelector(".components-list"));
    if ($list.length === 0 || ENV.environment === "test") {
      return;
    }
    const duration = 300;
    if (this.get("theme.selected")) {
      this.collapseComponentsList($container, $list, duration);
    } else if (!isInitial) {
      this.expandComponentsList($container, $list, duration);
    }
  },

  @discourseComputed(
    "theme.component",
    "theme.childThemes.@each.name",
    "theme.childThemes.length",
    "childrenExpanded"
  )
  children() {
    const theme = this.theme;
    let children = theme.get("childThemes");
    if (theme.get("component") || !children) {
      return [];
    }
    children = this.childrenExpanded
      ? children
      : children.slice(0, MAX_COMPONENTS);
    return children.map(t => {
      const name = escape(t.name);
      return t.enabled ? name : `${iconHTML("ban")} ${name}`;
    });
  },

  @discourseComputed("children")
  childrenString(children) {
    return children.join(", ");
  },

  @discourseComputed(
    "theme.childThemes.length",
    "theme.component",
    "childrenExpanded",
    "children.length"
  )
  moreCount(childrenCount, component, expanded) {
    if (component || !childrenCount || expanded) {
      return 0;
    }
    return childrenCount - MAX_COMPONENTS;
  },

  expandComponentsList($container, $list, duration) {
    $container.css("height", `${$container.height()}px`);
    $list.css("display", "");
    $container.animate(
      {
        height: `${$container.height() + $list.outerHeight(true)}px`
      },
      {
        duration,
        done: () => {
          $list.css("display", "");
          $container.css("height", "");
        }
      }
    );
    $list.animate(
      {
        opacity: 1
      },
      {
        duration
      }
    );
  },

  collapseComponentsList($container, $list, duration) {
    $container.animate(
      {
        height: `${$container.height() - $list.outerHeight(true)}px`
      },
      {
        duration,
        done: () => {
          $list.css("display", "none");
          $container.css("height", "");
        }
      }
    );
    $list.animate(
      {
        opacity: 0
      },
      {
        duration
      }
    );
  },

  actions: {
    toggleChildrenExpanded() {
      this.toggleProperty("childrenExpanded");
    }
  }
});
