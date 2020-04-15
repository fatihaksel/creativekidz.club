(function() {
  if (typeof I18n !== "undefined") {
    // Default format for storage units
    var oldI18ntoHumanSize = I18n.toHumanSize;
    I18n.toHumanSize = function(number, options) {
      options = options || {};
      options.format = I18n.t("number.human.storage_units.format");
      return oldI18ntoHumanSize.apply(this, [number, options]);
    };

    if ("w" in String.prototype) {
      String.prototype.i18n = function(options) {
        return I18n.t(String(this), options);
      };
    }
  }
})();
