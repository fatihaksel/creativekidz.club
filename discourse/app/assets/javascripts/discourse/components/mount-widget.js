import { cancel, scheduleOnce } from "@ember/runloop";
import Component from "@ember/component";
import { diff, patch } from "virtual-dom";
import { WidgetClickHook } from "discourse/widgets/hooks";
import { queryRegistry } from "discourse/widgets/widget";
import { getRegister } from "discourse-common/lib/get-owner";
import DirtyKeys from "discourse/lib/dirty-keys";
import { camelize } from "@ember/string";

let _cleanCallbacks = {};
export function addWidgetCleanCallback(widgetName, fn) {
  _cleanCallbacks[widgetName] = _cleanCallbacks[widgetName] || [];
  _cleanCallbacks[widgetName].push(fn);
}

export function resetWidgetCleanCallbacks() {
  _cleanCallbacks = {};
}

export default Component.extend({
  _tree: null,
  _rootNode: null,
  _timeout: null,
  _widgetClass: null,
  _renderCallback: null,
  _childEvents: null,
  _dispatched: null,
  dirtyKeys: null,

  init() {
    this._super(...arguments);
    const name = this.widget;

    this.register = getRegister(this);

    this._widgetClass =
      queryRegistry(name) || this.register.lookupFactory(`widget:${name}`);

    if (!this._widgetClass) {
      // eslint-disable-next-line no-console
      console.error(`Error: Could not find widget: ${name}`);
    }

    this._childEvents = [];
    this._connected = [];
    this._dispatched = [];
    this.dirtyKeys = new DirtyKeys(name);
  },

  didInsertElement() {
    WidgetClickHook.setupDocumentCallback();

    this._rootNode = document.createElement("div");
    this.element.appendChild(this._rootNode);
    this._timeout = scheduleOnce("render", this, this.rerenderWidget);
  },

  willClearRender() {
    const callbacks = _cleanCallbacks[this.widget];
    if (callbacks) {
      callbacks.forEach(cb => cb(this._tree));
    }

    this._connected.forEach(v => v.destroy());
    this._connected.length = 0;
  },

  willDestroyElement() {
    this._dispatched.forEach(evt => {
      const [eventName, caller] = evt;
      this.appEvents.off(eventName, this, caller);
    });
    cancel(this._timeout);
  },

  afterRender() {},

  beforePatch() {},

  afterPatch() {},

  eventDispatched(eventName, key, refreshArg) {
    const onRefresh = camelize(eventName.replace(/:/, "-"));
    this.dirtyKeys.keyDirty(key, { onRefresh, refreshArg });
    this.queueRerender();
  },

  dispatch(eventName, key) {
    this._childEvents.push(eventName);

    const caller = refreshArg =>
      this.eventDispatched(eventName, key, refreshArg);
    this._dispatched.push([eventName, caller]);
    this.appEvents.on(eventName, this, caller);
  },

  queueRerender(callback) {
    if (callback && !this._renderCallback) {
      this._renderCallback = callback;
    }

    scheduleOnce("render", this, this.rerenderWidget);
  },

  buildArgs() {},

  rerenderWidget() {
    cancel(this._timeout);

    if (this._rootNode) {
      if (!this._widgetClass) {
        return;
      }

      const t0 = Date.now();
      const args = this.args || this.buildArgs();
      const opts = {
        model: this.model,
        dirtyKeys: this.dirtyKeys
      };
      const newTree = new this._widgetClass(args, this.register, opts);

      newTree._rerenderable = this;
      newTree._emberView = this;
      const patches = diff(this._tree || this._rootNode, newTree);

      this.beforePatch();
      this._rootNode = patch(this._rootNode, patches);
      this.afterPatch();

      this._tree = newTree;

      if (this._renderCallback) {
        this._renderCallback();
        this._renderCallback = null;
      }
      this.afterRender();
      this.dirtyKeys.renderedKey("*");

      if (this.profileWidget) {
        // eslint-disable-next-line no-console
        console.log(Date.now() - t0);
      }
    }
  }
});
