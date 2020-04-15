## Discourse Security

We take security very seriously at Discourse. We welcome any peer review of our 100% open source code to ensure nobody's Discourse forum is ever compromised or hacked.

### Where should I report security issues?

In order to give the community time to respond and upgrade we strongly urge you report all security issues privately. Please use our [vulnerability disclosure program at Hacker One](https://hackerone.com/discourse) to provide details and repro steps and we will respond ASAP. If you prefer not to use Hacker One, email us directly at `team@discourse.org` with details and repro steps. Security issues *always* take precedence over bug fixes and feature work. We can and do mark releases as "urgent" if they contain serious security fixes.

For a list of recent security commits, check [our GitHub commits prefixed with SECURITY](https://github.com/discourse/discourse/search?o=desc&q=SECURITY&s=committer-date&type=Commits).

### Password Storage

Discourse uses the PBKDF2 algorithm to encrypt salted passwords. This algorithm is blessed by NIST. Security experts on the web [tend to agree that PBKDF2 is a secure choice](https://security.stackexchange.com/questions/4781/do-any-security-experts-recommend-bcrypt-for-password-storage).

**options you can customise in your production.rb file**

- `pbkdf2_algorithm`: the hashing algorithm used (default "sha256")
- `pbkdf2_iterations`: the number of iterations to run (default 64000)

### XSS

The main vector for [XSS](https://en.wikipedia.org/wiki/Cross-site_scripting) attacks is via the post composer, as we allow users to enter Markdown, HTML (a safe subset thereof), and BBCode to format posts.

There are 3 main scenarios we protect against:

1. **Markdown preview invokes an XSS.** This is possibly severe in one specific case: when a forum staff member edits a user's post, seeing the raw markup, where a malicious user may have inserted code to run JavaScript. This code would only show up in the preview, but it would run in the context of a forum staff member, which is *very* bad.

2. **Markdown displayed on the page invokes an XSS.** To protect against client side preview XSS, Discourse uses [Google Caja](https://developers.google.com/caja/) in the preview window.

3. **CSP is on by default** for [all Discourse installations](https://meta.discourse.org/t/mitigate-xss-attacks-with-content-security-policy/104243) as of Discourse 2.2. It can be switched off in the site settings, but it is default on.

On the server side we run a whitelist based sanitizer, implemented using the [Sanitize gem](https://github.com/rgrove/sanitize). See the [relevant Discourse code](https://github.com/discourse/discourse/blob/master/lib/pretty_text.rb).

In addition, titles and all other places where non-admins can enter code are protected either using the Handlebars library or standard Rails XSS protection.

### CSRF

[CSRF](https://en.wikipedia.org/wiki/Cross-site_request_forgery) allows malicious sites to perform HTTP requests in the context of a forum user without their knowledge -- mostly by getting users who already hold a valid forum login cookie to click a specific link in their web browser.

Discourse extends the built-in Rails CSRF protection in the following ways:

1. By default any non GET requests ALWAYS require a valid CSRF token. If a CSRF token is missing Discourse will raise an exception.

2. API calls using the secret API bypass CSRF checks.

3. Certain pages are "cachable", we do not render the CSRF token (`<meta name='csrf-token' ...`) on any cachable pages. Instead when users are about to perform the first non GET request they retrieve the token just in time via `GET session/csrf`

### DDOS

If you install via our recommended Docker image in our [install guide][ig], nginx is the front end web server. For additional DDOS protection we recommend placing [HAProxy](https://www.haproxy.org/) in front.

### Deployment concerns

We strongly recommend that the various Discourse processes (web server, sidekiq) run under a non-elevated account. This is handled automatically if you install via our recommended Docker image -- see [our install guide][ig] for details.

[ig]: https://github.com/discourse/discourse/blob/master/docs/INSTALL.md
