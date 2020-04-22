# Installation
This page describes the installation steps

## Plugins

Following plugins are activated

* Topic Preview https://github.com/angusmcleod/discourse-topic-previews

## Theme
Theme related customizations

* A customized theme for our web-app https://github.com/fatihaksel/creative-kidz-theme
* Custom Header Component --> https://github.com/discourse/discourse-custom-header-links
    ```
    Most Liked, Posts with the most amount of likes, /top, vdo, self, keep
    Parent's Survey, Please join our survey , https://www.surveymonkey.com/r/JQD8N37, vdo, blank, remove
    Code::Buffalo, This is a Hackathon project , https://www.43north.org/code-buffalo/, vdo, blank, remove
    About Us, About Us, t/welcome-to-creative-kidz/7, vdo, self, keep
    ```

## Installation

Connect to your server via its IP address using SSH, or Putty on Windows:

`ssh root@192.168.1.1`


**Install Docker / Git**

```
sudo -s
git clone https://github.com/fatihaksel/creativekidz.club.git /var discourse

cd /var/discourse

```
**Domain Name**
Discourse will not work from an IP address, you must own a domain name such as `example.com` to proceed.


**Edit Discourse Configuration**

Launch the setup tool at

`./discourse-setup`

Answer the following questions when prompted:
```
Hostname for your Discourse? [discourse.example.com]:
Email address for admin account(s)? [me@example.com,you@example.com]:
SMTP server address? [smtp.example.com]:
SMTP port? [587]:
SMTP user name? [user@example.com]:
SMTP password? [pa$$word]:
Let's Encrypt account email? (ENTER to skip) [me@example.com]:
```


This will generate an `app.yml` configuration file on your behalf, and then kicks off bootstrap. Bootstrapping takes between **2-8 minutes** to set up your Discourse. If you need to change these settings after bootstrapping, you can run `./discourse-setup` again (it will re-use your previous values from the file) or edit `/containers/app.yml` manually with `nano` and then `./launcher rebuild app`, otherwise your changes will not take effect.

**Start Discourse**

Once bootstrapping is complete, the web-site should be accessible in your web browser via the domain name `discourse.example.com` you entered earlier.
