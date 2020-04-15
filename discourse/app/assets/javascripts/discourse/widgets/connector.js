import { next } from "@ember/runloop";
import { setOwner, getOwner } from "@ember/application";

export default class Connector {
  constructor(widget, opts) {
    this.widget = widget;
    this.opts = opts;
  }

  init() {
    const $elem = $(`<div class='widget-connector'></div>`);
    const elem = $elem[0];

    const { opts, widget } = this;
    next(() => {
      const mounted = widget._findView();

      if (opts.component) {
        const connector = widget.register.lookupFactory(
          "component:connector-container"
        );

        const view = connector.create({
          layoutName: `components/${opts.component}`,
          model: widget.findAncestorModel()
        });

        setOwner(view, getOwner(mounted));

        mounted._connected.push(view);
        view.renderer.appendTo(view, $elem[0]);
      }
    });

    return elem;
  }

  update() {}
}

Connector.prototype.type = "Widget";
