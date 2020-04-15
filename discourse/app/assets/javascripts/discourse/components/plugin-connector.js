import Component from "@ember/component";
import { defineProperty, computed } from "@ember/object";
import deprecated from "discourse-common/lib/deprecated";
import { buildArgsWithDeprecations } from "discourse/lib/plugin-connectors";
import { afterRender } from "discourse-common/utils/decorators";

let _decorators = {};

// Don't call this directly: use `plugin-api/decoratePluginOutlet`
export function addPluginOutletDecorator(outletName, callback) {
  _decorators[outletName] = _decorators[outletName] || [];
  _decorators[outletName].push(callback);
}

export function resetDecorators() {
  _decorators = {};
}

export default Component.extend({
  init() {
    this._super(...arguments);

    const connector = this.connector;
    this.set("layoutName", connector.templateName);

    const args = this.args || {};
    Object.keys(args).forEach(key => {
      defineProperty(
        this,
        key,
        computed("args", () => (this.args || {})[key])
      );
    });

    const deprecatedArgs = this.deprecatedArgs || {};
    Object.keys(deprecatedArgs).forEach(key => {
      defineProperty(
        this,
        key,
        computed("deprecatedArgs", () => {
          deprecated(
            `The ${key} property is deprecated, but is being used in ${this.layoutName}`
          );

          return (this.deprecatedArgs || {})[key];
        })
      );
    });

    const connectorClass = this.get("connector.connectorClass");
    this.set("actions", connectorClass.actions);

    for (const [name, action] of Object.entries(this.actions)) {
      this.set(name, action);
    }

    const merged = buildArgsWithDeprecations(args, deprecatedArgs);
    connectorClass.setupComponent.call(this, merged, this);
  },

  didReceiveAttrs() {
    this._super(...arguments);

    this._decoratePluginOutlets();
  },

  @afterRender
  _decoratePluginOutlets() {
    (_decorators[this.connector.outletName] || []).forEach(dec =>
      dec(this.element, this.args)
    );
  },

  willDestroyElement() {
    this._super(...arguments);

    const connectorClass = this.get("connector.connectorClass");
    connectorClass.teardownComponent.call(this, this);
  },

  send(name, ...args) {
    const connectorClass = this.get("connector.connectorClass");
    const action = connectorClass.actions[name];
    return action ? action.call(this, ...args) : this._super(name, ...args);
  }
});
