export default {
  name: "localization",
  after: "inject-objects",

  isVerboseLocalizationEnabled(container) {
    const siteSettings = container.lookup("site-settings:main");
    if (siteSettings.verbose_localization) return true;

    try {
      return sessionStorage && sessionStorage.getItem("verbose_localization");
    } catch (e) {
      return false;
    }
  },

  initialize(container) {
    if (this.isVerboseLocalizationEnabled(container)) {
      I18n.enableVerboseLocalization();
    }

    // Merge any overrides into our object
    const overrides = I18n._overrides || {};
    Object.keys(overrides).forEach(k => {
      const v = overrides[k];
      k = k.replace("admin_js", "js");

      const segs = k.split(".");

      let node = I18n.translations[I18n.locale];
      let i = 0;

      for (; i < segs.length - 1; i++) {
        if (!(segs[i] in node)) node[segs[i]] = {};
        node = node[segs[i]];
      }

      if (typeof node === "object") {
        node[segs[segs.length - 1]] = v;
      }
    });

    const mfOverrides = I18n._mfOverrides || {};
    Object.keys(mfOverrides).forEach(k => {
      const v = mfOverrides[k];

      k = k.replace(/^[a-z_]*js\./, "");
      I18n._compiledMFs[k] = v;
    });

    bootbox.addLocale(I18n.currentLocale(), {
      OK: I18n.t("composer.modal_ok"),
      CANCEL: I18n.t("composer.modal_cancel"),
      CONFIRM: I18n.t("composer.modal_ok")
    });
    bootbox.setLocale(I18n.currentLocale());
  }
};
