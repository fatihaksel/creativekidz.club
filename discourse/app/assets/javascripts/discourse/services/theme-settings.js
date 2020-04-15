import { get } from "@ember/object";
import Service from "@ember/service";

export default Service.extend({
  settings: null,

  init() {
    this._super(...arguments);
    this._settings = {};
  },

  registerSettings(themeId, settingsObject) {
    this._settings[themeId] = settingsObject;
  },

  getSetting(themeId, settingsKey) {
    if (this._settings[themeId]) {
      return get(this._settings[themeId], settingsKey);
    }
    return null;
  },

  getObjectForTheme(themeId) {
    return this._settings[themeId];
  }
});
