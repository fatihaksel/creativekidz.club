// discourse-skip-module
(function() {
  const ps = require("preload-store").default;
  const preloadedDataElement = document.getElementById("data-preloaded");
  const setupData = document.getElementById("data-discourse-setup").dataset;

  if (preloadedDataElement) {
    const preloaded = JSON.parse(preloadedDataElement.dataset.preloaded);

    Object.keys(preloaded).forEach(function(key) {
      ps.store(key, JSON.parse(preloaded[key]));

      if (setupData.debugPreloadedAppData === "true") {
        /* eslint-disable no-console */
        console.log(key, ps.get(key));
        /* eslint-enable no-console */
      }
    });
  }

  window.Logster = window.Logster || {};
  window.Logster.enabled = setupData.enableJsErrorReporting === "true";

  Discourse.CDN = setupData.cdn;
  Discourse.BaseUrl = setupData.baseUrl;
  Discourse.BaseUri = setupData.baseUri;
  Discourse.Environment = setupData.environment;
  Discourse.SiteSettings = ps.get("siteSettings");
  Discourse.ThemeSettings = ps.get("themeSettings");
  Discourse.LetterAvatarVersion = setupData.letterAvatarVersion;
  Discourse.MarkdownItURL = setupData.markdownItUrl;
  Discourse.ServiceWorkerURL = setupData.serviceWorkerUrl;
  I18n.defaultLocale = setupData.defaultLocale;
  Discourse.start();
  Discourse.set("assetVersion", setupData.assetVersion);

  const Session = require("discourse/models/session").default;
  Session.currentProp(
    "disableCustomCSS",
    setupData.disableCustomCss === "true"
  );

  if (setupData.safeMode) {
    Session.currentProp("safe_mode", setupData.safeMode);
  }

  Discourse.HighlightJSPath = setupData.highlightJsPath;
  Discourse.SvgSpritePath = setupData.svgSpritePath;

  if (Discourse.Environment === "development") {
    Discourse.SvgIconList = setupData.svgIconList;
  }

  if (setupData.s3BaseUrl) {
    Discourse.S3CDN = setupData.s3Cdn;
    Discourse.S3BaseUrl = setupData.s3BaseUrl;
  }

  // eslint-disable-next-line
  Ember.RSVP.configure("onerror", function(e) {
    // Ignore TransitionAborted exceptions that bubble up
    if (e && e.message === "TransitionAborted") {
      return;
    }

    if (Discourse.Environment === "development") {
      /* eslint-disable no-console  */
      if (e) {
        if (e.message || e.stack) {
          console.log(e.message);
          console.log(e.stack);
        } else {
          console.log("Uncaught promise: ", e);
        }
      } else {
        console.log("A promise failed but was not caught.");
      }
      /* eslint-enable no-console  */
    }

    window.onerror(e && e.message, null, null, null, e);
  });
})();
